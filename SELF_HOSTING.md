# Tự host máy chủ Mesh cho Chế độ 2 — MacViewer Ventura 5.0

Tài liệu này hướng dẫn bạn tự chạy máy chủ Mesh của riêng mình, từng bước một, kể cả khi bạn chưa từng chạy máy chủ bao giờ. Chế độ 2 ("Tự host") của MacViewer Ventura 5.0 không đi kèm máy chủ công cộng của dự án: hai máy tính chỉ tìm thấy nhau khi có một máy chủ Mesh do chính bạn (hoặc người quen của bạn) vận hành. Mỗi bước dưới đây đều cho sẵn lệnh cần gõ và kết quả đúng mà bạn phải nhìn thấy, để bạn tự kiểm tra được mình đang ở đâu.

## 1. Máy chủ Mesh làm gì và không làm gì

Máy chủ Mesh là một chương trình nhỏ, nhẹ, chỉ làm bốn việc:

- **Đăng ký thiết bị.** Mỗi máy tính cài MacViewer Ventura tự tạo cho mình một cặp khóa (một khóa bí mật giữ trên máy, một khóa công khai gửi lên máy chủ). Khi đăng ký thành công, máy chủ cấp cho thiết bị một **Mesh ID** — số định danh gồm 9 chữ số, hiển thị theo nhóm 3-3-3, đóng vai trò như số điện thoại của thiết bị trên máy chủ của bạn.
- **Giữ danh sách ai đã đồng ý kết nối với ai.** Muốn kết nối, một bên gửi yêu cầu ghép nối tới Mesh ID của bên kia, và bên kia phải bấm đồng ý. Chỉ khi đã ghép nối, hai máy mới được nói chuyện qua máy chủ. Máy chủ không bao giờ tự ghép nối thay người dùng.
- **Chuyển tiếp tín hiệu kết nối.** Trước khi có hình ảnh, hai máy cần trao đổi vài tin nhắn nhỏ để tìm đường tới nhau và thỏa thuận cách kết nối; những tin nhắn này gọi là **tín hiệu kết nối** (signaling). Máy chủ chỉ chuyển tiếp các tin nhắn đó giữa hai máy đã ghép nối.
- **Cho biết ai đang trực tuyến.** Một thiết bị được coi là đang trực tuyến khi ứng dụng của nó đang mở và đang giữ kết nối tới máy chủ.

Những việc máy chủ **không** làm, và bạn nên biết rõ:

- **Hình ảnh và thao tác điều khiển không đi qua máy chủ.** Sau bước tín hiệu, hình ảnh màn hình và lệnh chuột/phím chạy trực tiếp giữa hai máy tính, được mã hóa đầu cuối. Máy chủ không nhìn thấy, không lưu trữ hình ảnh của bạn.
- **Máy chủ không có tài khoản người dùng và không giữ mật khẩu.** Danh tính của một thiết bị là khóa bí mật nằm trên chính thiết bị đó.
- **Tin nhắn chat đi qua máy chủ của bạn** (máy chủ chuyển tiếp chúng như một loại tín hiệu), vì vậy hãy chỉ cấp mã mời cho người bạn tin cậy.

## 2. Bạn cần chuẩn bị gì

Trước khi bắt đầu, hãy chuẩn bị ba thứ sau:

- **Một máy để chạy máy chủ.** Đó có thể là một **VPS** (máy chủ ảo bạn thuê theo tháng từ một nhà cung cấp), một máy tính để bàn ở nhà luôn bật, hoặc một máy Mac mini. Điều kiện duy nhất: cả hai máy tính cần điều khiển nhau đều phải kết nối tới được máy này. Máy chủ rất nhẹ: chương trình chỉ khoảng 17 MB, dữ liệu ban đầu chỉ vài kilobyte, nên bất kỳ máy nào chạy được Linux hoặc macOS đều thừa sức.
- **Go 1.26 trở lên trên máy sẽ biên dịch chương trình** (tải miễn phí tại https://go.dev/dl/). Bạn chỉ cần biên dịch một lần: kết quả là một file chương trình duy nhất, không phụ thuộc thêm thư viện nào, và bạn có thể chép file đó sang máy khác cùng hệ điều hành và cùng dòng CPU để chạy. Cách đơn giản nhất là biên dịch ngay trên máy sẽ chạy máy chủ.
- **Một cổng mạng để máy chủ lắng nghe.** Hướng dẫn này dùng cổng **8734**, là cổng mặc định của chương trình. Nếu cổng này đã bị chương trình khác chiếm trên máy của bạn, hãy chọn một số khác (ví dụ 18734) và thay vào mọi bước dưới đây.

## 3. Bước 1 — Lấy mã nguồn và biên dịch chương trình

Bước này tải mã nguồn của MacViewer Ventura (trong đó có sẵn thư mục `mesh-server`) và biên dịch ra chương trình máy chủ.

Nếu máy của bạn có Git, hãy chạy hai lệnh sau để tải mã nguồn và đi vào thư mục máy chủ:

```sh
git clone https://github.com/ArtyormSatori/MacViewer-Ventura.git
cd MacViewer-Ventura/mesh-server
```

Nếu không dùng Git, hãy tải file mã nguồn `MacViewer-Ventura-5.0-Source.zip` đính kèm bản phát hành 5.0, giải nén, rồi mở Terminal tại thư mục vừa giải nén và đi vào thư mục `mesh-server` bên trong.

Tiếp theo, kiểm tra phiên bản Go đã đủ mới chưa:

```sh
go version
```

Kết quả phải hiện một dòng dạng `go version go1.26.0 ...` hoặc mới hơn. Nếu số phiên bản nhỏ hơn 1.26, bản Go đó quá cũ và bước biên dịch sẽ báo lỗi ngay; hãy cài bản mới hơn rồi quay lại.

Giờ biên dịch chương trình máy chủ:

```sh
go build -o meshserver ./cmd/meshserver
```

Lệnh thành công sẽ **không in ra gì cả**. Kiểm tra kết quả bằng lệnh sau:

```sh
ls -la meshserver
```

Bạn phải thấy một file tên `meshserver`, kích thước khoảng 17 MB, có quyền thực thi. Đây là toàn bộ chương trình máy chủ.

## 4. Bước 2 — Tạo mã mời

**Mã mời** là một chuỗi bí mật đóng vai trò như mật khẩu dùng một lần: một thiết bị hoàn toàn mới chỉ được đăng ký lên máy chủ của bạn khi nó xuất trình một mã mời chưa ai dùng. Mỗi thiết bị mới cần một mã riêng.

Lệnh sau tạo một mã mời ngẫu nhiên:

```sh
openssl rand -hex 16
```

Kết quả là một dòng gồm 32 ký tự hệ thập lục phân, ví dụ `3ab8178e7a0828689f420071a602d74f`. Hãy chạy lệnh này vài lần để có sẵn vài mã (mỗi máy tính bạn định dùng cần một mã), và ghi chúng vào nơi an toàn như bạn vẫn giữ mật khẩu.

## 5. Bước 3 — Viết file cấu hình

Máy chủ đọc toàn bộ cấu hình từ một file JSON nhỏ tên `config.json`. Bước này tạo file đó ngay trong thư mục `mesh-server`.

Tạo file `config.json` với nội dung sau, thay phần trong ngoặc bằng mã mời bạn vừa tạo (có bao nhiêu mã thì liệt kê bấy nhiêu, cách nhau bằng dấu phẩy):

```json
{
  "listen": "0.0.0.0:8734",
  "data_dir": "./data",
  "invites": ["dán-mã-mời-thứ-nhất-vào-đây", "dán-mã-mời-thứ-hai-vào-đây"]
}
```

Ba trường trong file có ý nghĩa như sau:

- `listen` là địa chỉ và cổng mà máy chủ lắng nghe. Giá trị `"0.0.0.0:8734"` có nghĩa là "nhận kết nối trên mọi địa chỉ mạng của máy này, cổng 8734" — đây là lựa chọn đúng khi các máy tính khác kết nối thẳng tới máy chủ (máy trong cùng mạng nhà, hoặc VPS không dùng thêm lớp trung gian). Giá trị `"127.0.0.1:8734"` có nghĩa là "chỉ nhận kết nối từ chính máy này" — chỉ dùng khi có một chương trình khác trên cùng máy đứng ra nhận kết nối từ bên ngoài rồi chuyển vào, như trường hợp đặt máy chủ sau Caddy ở bước 7, hoặc khi bạn chỉ muốn chạy thử trên một máy.
- `data_dir` là thư mục chứa toàn bộ dữ liệu của máy chủ (danh sách thiết bị, mã mời đã dùng, các ghép nối đã được duyệt). Thư mục này sẽ được tạo tự động khi máy chủ chạy lần đầu.
- `invites` là danh sách mã mời bạn gieo sẵn. Máy chủ nạp danh sách này mỗi khi khởi động; mã nào đã bị dùng sẽ vẫn ở trạng thái đã dùng, không bao giờ sống lại.

Nếu bạn quên tạo file cấu hình và chạy máy chủ luôn, chương trình dùng giá trị mặc định: chỉ lắng nghe trên chính máy đó (`127.0.0.1:8734`) và **không có mã mời nào**, tức là không thiết bị mới nào đăng ký được. Vì vậy file cấu hình là bắt buộc nếu muốn dùng thật.

## 6. Bước 4 — Chạy thử lần đầu và kiểm tra

Bước này chạy máy chủ ở chế độ hiển thị trực tiếp trên Terminal, để bạn nhìn thấy nó khởi động thành công trước khi cho chạy nền lâu dài.

Chạy lệnh sau trong thư mục `mesh-server`:

```sh
./meshserver -config config.json
```

Máy chủ khởi động đúng sẽ in một dòng nhật ký dạng JSON, trong đó có đoạn `"msg":"mesh server listening"` kèm địa chỉ bạn đã cấu hình, và con trỏ Terminal dừng ở đó (chương trình đang chạy, chưa kết thúc). Hãy để nguyên cửa sổ này.

Mở một cửa sổ Terminal thứ hai và kiểm tra máy chủ có sống không bằng lệnh:

```sh
curl http://127.0.0.1:8734/healthz
```

Kết quả đúng phải là đúng dòng chữ này:

```json
{"status":"ok"}
```

Tiếp theo, kiểm tra thêm rằng máy tính khác cũng với tới được máy chủ, vì đây là điều kiện để ứng dụng hoạt động. Trên máy chạy máy chủ, tìm địa chỉ IP nội mạng của nó (trên Linux dùng lệnh `hostname -I`, trên macOS dùng lệnh `ipconfig getifaddr en0`). Sau đó, từ một máy tính khác trong cùng mạng, chạy:

```sh
curl http://192.168.1.10:8734/healthz
```

(thay `192.168.1.10` bằng địa chỉ IP vừa tìm được). Nếu vẫn nhận được `{"status":"ok"}`, đường mạng đã thông. Nếu lệnh treo hoặc báo không kết nối được, nguyên nhân thường là tường lửa trên máy chạy máy chủ chưa cho phép cổng 8734 — xem mục xử lý sự cố ở cuối tài liệu.

Khi kiểm tra xong, quay lại cửa sổ Terminal thứ nhất và bấm `Ctrl+C` để dừng máy chủ chạy thử.

## 7. Bước 5 — Cho máy chủ chạy nền lâu dài

Chạy thử đã ổn thì bạn nên cho máy chủ chạy như một **dịch vụ nền** (chương trình tự khởi động cùng máy và tự chạy lại nếu bị dừng ngoài ý muốn), thay vì giữ một cửa sổ Terminal mở mãi. Chọn phần đúng với hệ điều hành của máy chạy máy chủ.

### 7a. Trên Linux: dùng systemd

**systemd** là trình quản lý dịch vụ có sẵn trên hầu hết các bản Linux (Ubuntu, Debian...). Các lệnh dưới đây đưa chương trình và cấu hình vào thư mục `/opt/meshserver`, tạo một tài khoản riêng không có quyền quản trị để chạy dịch vụ (để nếu chương trình có sự cố, nó không chạy bằng quyền cao nhất của máy), rồi đăng ký dịch vụ.

Từ thư mục `mesh-server` nơi bạn đã biên dịch, chạy lần lượt:

```sh
sudo mkdir -p /opt/meshserver
sudo cp meshserver config.json /opt/meshserver/
sudo adduser --system --group --home /opt/meshserver meshserver
sudo chown -R meshserver:meshserver /opt/meshserver
```

Trong các lệnh trên, tài khoản `meshserver` được tạo ra chỉ để chạy dịch vụ này; thư mục dữ liệu `./data` trong cấu hình sẽ nằm tại `/opt/meshserver/data` vì dịch vụ được đặt thư mục làm việc là `/opt/meshserver` (dòng `WorkingDirectory` trong file dịch vụ ở ngay dưới đây).

Tiếp theo, tạo file mô tả dịch vụ bằng trình soạn thảo:

```sh
sudo nano /etc/systemd/system/meshserver.service
```

Dán nội dung sau vào, lưu lại và thoát:

```ini
[Unit]
Description=MacViewer Ventura mesh server (Mode 2 self-hosted)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=meshserver
WorkingDirectory=/opt/meshserver
ExecStart=/opt/meshserver/meshserver -config /opt/meshserver/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Đăng ký và khởi động dịch vụ:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now meshserver
```

Lệnh thứ hai thành công sẽ in một dòng dạng `Created symlink ...` cho biết dịch vụ đã được hẹn tự chạy cùng máy. Kiểm tra trạng thái dịch vụ:

```sh
systemctl status meshserver
```

Kết quả đúng phải có dòng `Active: active (running)`. Kiểm tra thêm bằng lệnh kiểm tra sức khỏe quen thuộc:

```sh
curl http://127.0.0.1:8734/healthz
```

Vẫn phải nhận được `{"status":"ok"}`. Từ đây, hai lệnh bạn sẽ dùng thường xuyên là `sudo systemctl restart meshserver` (khởi động lại sau khi sửa cấu hình) và `journalctl -u meshserver -f` (xem nhật ký trực tiếp; bấm `Ctrl+C` để thoát khỏi màn hình nhật ký, máy chủ vẫn chạy).

### 7b. Trên macOS: dùng launchd

**launchd** là trình quản lý dịch vụ có sẵn của macOS, tương đương systemd trên Linux. Các bước dưới đây đặt chương trình vào thư mục `~/meshserver` trong tài khoản của bạn (không cần quyền quản trị) và đăng ký một dịch vụ người dùng tự chạy khi bạn đăng nhập.

Từ thư mục `mesh-server` nơi bạn đã biên dịch, chạy:

```sh
mkdir -p ~/meshserver
cp meshserver config.json ~/meshserver/
```

Tạo file mô tả dịch vụ tại `~/Library/LaunchAgents/dev.macviewer.meshserver.plist` với nội dung sau. Lưu ý thay `yourname` bằng tên tài khoản macOS của bạn (chạy lệnh `whoami` nếu bạn không chắc), vì launchd không hiểu ký tự `~` trong file này:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.macviewer.meshserver</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/yourname/meshserver/meshserver</string>
		<string>-config</string>
		<string>/Users/yourname/meshserver/config.json</string>
	</array>
	<key>WorkingDirectory</key>
	<string>/Users/yourname/meshserver</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/Users/yourname/meshserver/server.log</string>
	<key>StandardErrorPath</key>
	<string>/Users/yourname/meshserver/server.log</string>
</dict>
</plist>
```

Nạp dịch vụ và kiểm tra:

```sh
launchctl load ~/Library/LaunchAgents/dev.macviewer.meshserver.plist
curl http://127.0.0.1:8734/healthz
```

Nhận được `{"status":"ok"}` là dịch vụ đã chạy. Nhật ký của máy chủ nằm trong file `~/meshserver/server.log`. Muốn dừng dịch vụ, chạy `launchctl unload ~/Library/LaunchAgents/dev.macviewer.meshserver.plist`.

## 8. Bước 6 — Mở đường từ bên ngoài và HTTPS cho kết nối qua Internet

Nếu cả hai máy tính và máy chủ đều ở trong cùng một mạng nhà, bạn không cần bước này: địa chỉ dạng `http://192.168.1.10:8734` là đủ, và việc dùng HTTP không mã hóa trong mạng nhà của chính bạn là lựa chọn thực tế, chấp nhận được.

Nếu máy chủ đặt trên VPS hoặc bạn muốn kết nối từ ngoài Internet, cần thêm hai việc:

**Mở cổng trên tường lửa.** **Tường lửa** là lớp kiểm soát cổng nào của máy được phép nhận kết nối từ bên ngoài. Trên VPS chạy Ubuntu có bật `ufw`, mở cổng bằng lệnh:

```sh
sudo ufw allow 8734/tcp
```

Nhiều nhà cung cấp VPS còn có một lớp tường lửa riêng trên trang quản trị của họ (thường gọi là "security group" hoặc "firewall rules") — hãy mở cổng TCP 8734 ở đó nữa. Nếu máy chủ là máy tính ở nhà, bạn cần vào trang quản trị của router và tạo một quy tắc **chuyển tiếp cổng** (port forwarding): chuyển cổng TCP 8734 từ bên ngoài vào đúng địa chỉ IP nội mạng của máy chạy máy chủ, đồng thời nên gán cho máy đó một địa chỉ IP nội mạng cố định trong phần cài đặt DHCP của router, để địa chỉ không đổi sau mỗi lần khởi động lại.

**Đặt máy chủ sau HTTPS bằng Caddy.** Khi kết nối đi qua Internet, hãy để đường truyền được mã hóa. Cách gọn nhất là dùng **Caddy** — một chương trình đóng vai trò **máy chủ trung gian ngược** (reverse proxy): nó đứng trước máy chủ Mesh, nhận kết nối HTTPS đã mã hóa từ bên ngoài (kèm chứng thư số mà nó tự xin cấp, bạn không phải mua hay cấu hình tay), rồi chuyển tiếp vào máy chủ Mesh đang chạy trên cùng máy. Điều kiện: bạn có một tên miền (ví dụ `mesh.example.com`) đã trỏ bản ghi DNS về địa chỉ IP của VPS, và cổng 80 cùng 443 được mở trên tường lửa.

Cài Caddy theo hướng dẫn chính thức tại https://caddyserver.com/docs/install, sau đó sửa cấu hình của máy chủ Mesh: đổi `listen` trong `config.json` về `"127.0.0.1:8734"` (để từ bên ngoài chỉ Caddy mới chạm được vào, tránh đi vòng qua lớp mã hóa) và khởi động lại dịch vụ Mesh. Tạo file `/etc/caddy/Caddyfile` với nội dung:

```
mesh.example.com {
	reverse_proxy 127.0.0.1:8734
}
```

(thay `mesh.example.com` bằng tên miền của bạn). Khởi động lại Caddy bằng lệnh `sudo systemctl restart caddy`, rồi kiểm tra từ một máy bất kỳ trên Internet:

```sh
curl https://mesh.example.com/healthz
```

Nhận được `{"status":"ok"}` là toàn bộ chuỗi đã thông. Từ đây, địa chỉ máy chủ bạn sẽ điền vào ứng dụng là `https://mesh.example.com` (không cần ghi cổng, vì HTTPS mặc định dùng cổng 443 và Caddy lo phần còn lại).

Một giới hạn của bản 5.0 bạn cần biết ngay từ đầu: **hình ảnh và điều khiển chỉ chạy được khi hai máy tính với tới nhau trực tiếp** — cùng một mạng nội bộ, hoặc cùng tham gia một mạng riêng ảo (VPN) khiến chúng "nhìn thấy" nhau như cùng mạng. Khi hai máy ở hai mạng nhà khác nhau và kết nối qua Internet công cộng, bộ định tuyến ở hai đầu thường chặn đường trực tiếp này; cách giải quyết chuẩn là một máy chủ **TURN** (máy chủ chuyển tiếp dự phòng cho hình ảnh khi đường trực tiếp không thông). Bản 5.0 chưa kèm TURN và hướng dẫn TURN sẽ được bổ sung sau. Trong lúc đó, ghép nối và chat vẫn hoạt động bình thường qua Internet, vì chúng đi qua máy chủ Mesh của bạn chứ không cần đường trực tiếp.

## 9. Bước 7 — Kết nối ứng dụng vào máy chủ của bạn

Làm lần lượt trên từng máy tính bạn muốn dùng Chế độ 2.

**Điền địa chỉ máy chủ.** Mở MacViewer Ventura, vào phần Cài đặt, tìm mục máy chủ tự host và điền địa chỉ máy chủ của bạn vào ô "Địa chỉ máy chủ". Điền đúng dạng bạn đã dựng: `http://192.168.1.10:8734` nếu dùng trong mạng nhà, hoặc `https://mesh.example.com` nếu đã đặt sau Caddy. Nếu để trống ô này, ứng dụng dùng một địa chỉ mặc định có sẵn trong bản cài — đó không phải máy chủ của bạn, nên khi tự host hãy luôn tự điền. Thay đổi có hiệu lực ở lần kết nối Chế độ 2 tiếp theo.

**Đăng ký thiết bị.** Chuyển cửa sổ chính sang chế độ "Tự host". Lần đầu tiên, ứng dụng yêu cầu bạn nhập một **mã mời**: hãy nhập một mã chưa dùng trong file cấu hình. Kết quả đúng: thẻ "Thiết bị này" hiện Mesh ID của máy bạn (9 chữ số, nhóm 3-3-3) và trạng thái đã kết nối tới máy chủ. Nếu mã sai hoặc đã bị dùng, máy chủ sẽ từ chối (nó trả về lỗi 403 "a valid invite code is required") và ứng dụng báo đăng ký thất bại — xem mục xử lý sự cố. Lưu ý: mã mời chỉ cần cho lần đăng ký đầu tiên của một thiết bị; cùng một thiết bị đăng ký lại sẽ nhận lại đúng Mesh ID cũ mà không cần mã mới. Nhưng nếu bạn cài lại ứng dụng từ đầu (thiết bị tạo khóa mới), nó được coi là thiết bị mới và cần một mã mời mới.

**Ghép nối hai máy.** Lặp lại hai bước trên ở máy thứ hai, với địa chỉ máy chủ giống hệt và một mã mời riêng khác. Sau đó, trên máy thứ nhất, nhập Mesh ID của máy thứ hai vào ô kết nối theo Mesh ID và gửi yêu cầu ghép nối. Trên máy thứ hai (ứng dụng đang mở), yêu cầu sẽ hiện ra; bấm đồng ý. Kết quả đúng: máy thứ hai xuất hiện trong danh sách thiết bị đã ghép nối của máy thứ nhất, và ngược lại. Các ghép nối **thuộc về máy chủ đã duyệt chúng**: nếu sau này bạn chuyển ứng dụng sang một máy chủ khác, bạn sẽ ghép nối lại từ đầu ở máy chủ đó; ghép nối ở máy chủ cũ không tự đi theo.

**Kết nối điều khiển.** Bấm nút "Kết nối" bên cạnh thiết bị đã ghép nối. Máy bên kia nhận được một cửa sổ xin phép ghi rõ tên và Mesh ID của máy bạn; người bên kia bấm đồng ý thì phiên bắt đầu và bạn nhìn thấy màn hình của họ. Trên cùng một mạng nội bộ, huy hiệu đường truyền trong cửa sổ phiên sẽ hiện **"Trực tiếp"** (Direct) — nghĩa là hình ảnh đi thẳng giữa hai máy. Huy hiệu **"Qua relay"** (Relay) nghĩa là hình ảnh phải đi vòng qua một máy chủ TURN; như đã nói ở bước 6, bản 5.0 chưa cấu hình TURN nên thông thường bạn sẽ chỉ gặp "Trực tiếp".

## 10. Vận hành hằng ngày

- **Sao lưu.** Toàn bộ trạng thái của máy chủ nằm trong thư mục `data_dir` (file `mesh.db` bên trong). Muốn sao lưu, hãy dừng dịch vụ trước rồi chép cả thư mục dữ liệu đi nơi an toàn, xong khởi động lại dịch vụ. Dừng trước khi chép giúp bản sao nhất quán, vì khi đang chạy máy chủ còn giữ thêm hai file tạm đi kèm (`mesh.db-wal` và `mesh.db-shm`).
- **Thêm mã mời.** Sinh thêm mã bằng lệnh ở bước 2, thêm chúng vào danh sách `invites` trong file cấu hình mà dịch vụ đang dùng, rồi khởi động lại dịch vụ (`sudo systemctl restart meshserver` trên Linux, hoặc `launchctl unload` rồi `launchctl load` như bước 7b trên macOS). Mã đã dùng rồi thì vẫn ở trạng thái đã dùng sau khi khởi động lại; bạn không thể "làm mới" một mã đã cấp cho thiết bị khác.
- **Kiểm tra nhanh.** Bất cứ lúc nào, `curl http://127.0.0.1:8734/healthz` (hoặc qua địa chỉ công cộng của bạn) trả về `{"status":"ok"}` nghĩa là máy chủ đang sống.
- **Cập nhật.** Khi có bản mới: tải mã nguồn mới, biên dịch lại như bước 1, dừng dịch vụ, thay file `meshserver` mới vào chỗ file cũ, rồi khởi động lại. File cấu hình và thư mục dữ liệu giữ nguyên, không phải làm lại gì.
- **Máy chủ tự dọn dữ liệu cũ.** Mỗi phiên kết nối chỉ để lại một dòng siêu dữ liệu (cặp hai thiết bị và thời điểm bắt đầu), và máy chủ tự xóa các dòng quá 30 ngày mỗi lần khởi động. Bạn không cần dọn tay.

## 11. Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp | Cách kiểm tra và xử lý |
|---|---|---|
| Ứng dụng báo không kết nối được máy chủ, đăng ký thất bại ngay | Sai địa chỉ hoặc cổng; máy chủ chưa chạy; `listen` đang là `127.0.0.1` nhưng ứng dụng ở máy khác; tường lửa chặn cổng 8734 | Chạy `curl http://<địa-chỉ-máy-chủ>:8734/healthz` ngay trên máy cài ứng dụng. Không nhận được `{"status":"ok"}` thì lỗi nằm ở đường mạng hoặc máy chủ, chưa phải ở ứng dụng. Kiểm tra dịch vụ còn chạy không, `listen` có đúng ý định không, và cổng đã mở trên tường lửa chưa. |
| Mã mời bị từ chối | Mã đã bị dùng cho thiết bị khác; gõ sai ký tự; dịch vụ đang đọc một file cấu hình hoặc thư mục dữ liệu khác với chỗ bạn vừa sửa | Sinh một mã hoàn toàn mới, thêm vào đúng file `config.json` mà dịch vụ đang dùng, khởi động lại dịch vụ rồi thử lại. Nhớ rằng mã đã dùng không bao giờ dùng lại được, kể cả sau khi khởi động lại máy chủ. |
| Thiết bị bên kia hiện "ngoại tuyến" | Ứng dụng bên kia chưa mở; bên kia đăng ký trên một máy chủ khác (địa chỉ khác); máy bên kia đang ngủ | Mở ứng dụng ở cả hai đầu và đối chiếu ô "Địa chỉ máy chủ" phải giống hệt nhau. Một thiết bị chỉ "trực tuyến" khi ứng dụng của nó đang mở và đang kết nối tới máy chủ. |
| Yêu cầu ghép nối không bao giờ tới | Ứng dụng bên kia chưa mở (yêu cầu được máy chủ giữ lại và chỉ hiện khi ứng dụng bên kia mở và trực tuyến; ứng dụng tự kiểm tra yêu cầu mới khoảng 20 giây một lần); gõ sai Mesh ID; hai máy đăng ký trên hai máy chủ khác nhau | Kiểm tra lại đủ 9 chữ số của Mesh ID, mở ứng dụng ở máy bên kia và chờ tối đa khoảng nửa phút. |
| Phiên kết nối được nhưng không có hình, hoặc màn hình đen | Máy chủ bị điều khiển (máy host) chưa cấp quyền Ghi màn hình cho MacViewer; để điều khiển được còn cần quyền Trợ năng | Trên máy Mac bị điều khiển: vào Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Ghi màn hình, bật cho MacViewer Ventura; vào mục Trợ năng và bật tương tự nếu cần điều khiển. Cấp quyền xong phải mở lại ứng dụng. Máy host cũng phải đang thức và đã mở khóa màn hình. |
| Chat được nhưng màn hình/điều khiển không kết nối khi hai máy ở hai mạng khác nhau | Hình ảnh cần đường trực tiếp giữa hai máy; hai bộ định tuyến gia đình thường chặn đường này và bản 5.0 chưa có máy chủ TURN | Cho cả hai máy vào cùng một mạng nội bộ hoặc cùng một VPN rồi thử lại. Ghép nối và chat vẫn dùng được qua Internet vì chúng đi qua máy chủ Mesh. |
| Huy hiệu đường truyền hiện "Qua relay" thay vì "Trực tiếp" | Hình ảnh đang đi vòng qua một máy chủ TURN thay vì đi thẳng | Đây là thông tin trạng thái, không phải lỗi. "Trực tiếp" là đường đi mong đợi khi hai máy cùng mạng; "Qua relay" chỉ xuất hiện khi đã có TURN được cấu hình (hướng dẫn TURN sẽ có sau). Dù theo đường nào, hình ảnh cũng không đi qua máy chủ Mesh. |

## 12. Ghi chú bảo mật

- **Khóa bí mật không bao giờ rời khỏi thiết bị.** Trên máy Mac, khóa của thiết bị được giữ trong Keychain. Máy chủ chỉ nhận và lưu khóa công khai — thứ vốn được sinh ra để công khai.
- **Máy chủ lưu những gì:** khóa công khai và tên của từng thiết bị, danh sách các ghép nối đã được duyệt, trạng thái đã dùng của từng mã mời, và một dòng siêu dữ liệu cho mỗi phiên (cặp thiết bị và thời điểm bắt đầu), tự xóa sau 30 ngày. Máy chủ không lưu hình ảnh, không lưu nội dung điều khiển.
- **Ai có địa chỉ máy chủ của bạn cộng với một mã mời còn hiệu lực thì đăng ký được thiết bị mới.** Hãy giữ mã mời như giữ mật khẩu: không đăng công khai, không gửi qua kênh không tin cậy. Nếu nghi ngờ một mã chưa dùng đã bị lộ, xóa mã đó khỏi file cấu hình và khởi động lại dịch vụ — mã sẽ không còn hiệu lực.
- **Khi máy chủ lộ ra Internet, hãy đặt nó sau HTTPS** như hướng dẫn Caddy ở bước 6, để địa chỉ, mã mời và tin nhắn chat không truyền đi ở dạng đọc được trên đường truyền.
- **Chỉ cấp mã mời cho người bạn tin cậy.** Người được ghép nối và được bạn đồng ý cho phiên vẫn phải được bạn chấp thuận từng lần ở cửa sổ xin phép, nhưng tin nhắn chat đi qua máy chủ của bạn — hãy coi máy chủ Mesh như một phòng chung của những người quen biết.

---
# Self-hosting the Mode 2 Mesh Server — MacViewer Ventura 5.0

This guide walks you through running your own Mesh server, step by step, even if you have never run a server before. MacViewer Ventura 5.0's Mode 2 ("Self-hosted") does not come with a public project server: two computers can only find each other when a Mesh server run by you (or by someone you know) is in the middle. Every step below gives you the exact command to type and the correct result you should see, so you can always check where you stand.

## 1. What the Mesh server does and does not do

The Mesh server is a small, light program that does only four things:

- **It registers devices.** Each computer running MacViewer Ventura creates a keypair for itself (a secret key that stays on the computer, and a public key that is sent to the server). On successful registration the server assigns the device a **Mesh ID** — a 9-digit identifier, displayed grouped 3-3-3, which works like the device's phone number on your server.
- **It remembers who has agreed to connect to whom.** To connect, one side sends a pairing request to the other side's Mesh ID, and the other side must approve it. Only paired devices may talk to each other through the server. The server never pairs devices on anyone's behalf.
- **It relays connection signals.** Before any picture flows, the two computers exchange a few small messages to find a path to each other and agree on how to connect; these messages are called **signaling**. The server only forwards them between paired devices.
- **It reports who is online.** A device counts as online while its app is open and holding a connection to the server.

And what the server does **not** do — you should know this clearly:

- **Your screen picture and control actions never pass through the server.** After the signaling step, the screen picture and the mouse/keyboard actions run directly between the two computers, encrypted end to end. The server never sees or stores your picture.
- **The server has no user accounts and stores no passwords.** A device's identity is the secret key living on the device itself.
- **Chat messages do pass through your server** (it relays them like a kind of signal), so only hand invite codes to people you trust.

## 2. What you need before starting

Prepare these three things:

- **A machine to run the server on.** This can be a **VPS** (a virtual server you rent by the month from a provider), an always-on desktop computer at home, or a Mac mini. The only condition: both computers that will control each other must be able to reach this machine. The server is very light — the program is about 17 MB and its data starts at a few kilobytes — so any machine running Linux or macOS is more than enough.
- **Go 1.26 or newer on the machine that will compile the program** (free download at https://go.dev/dl/). You compile only once: the result is a single program file with no other dependencies, and you may copy that file to another machine with the same operating system and CPU family to run it there. The simplest approach is to compile right on the machine that will run the server.
- **A network port for the server to listen on.** This guide uses port **8734**, the program's default. If something else on your machine already uses that port, pick another number (for example 18734) and use it in every step below.

## 3. Step 1 — Get the source code and build the program

This step downloads the MacViewer Ventura source code (which includes the `mesh-server` folder) and builds the server program from it.

If your machine has Git, run these two commands to download the source and enter the server folder:

```sh
git clone https://github.com/ArtyormSatori/MacViewer-Ventura.git
cd MacViewer-Ventura/mesh-server
```

If you do not use Git, download the `MacViewer-Ventura-5.0-Source.zip` file attached to the 5.0 release, unzip it, open a terminal in the unzipped folder, and move into the `mesh-server` folder inside it.

Next, check that your Go version is new enough:

```sh
go version
```

The output must be a line like `go version go1.26.0 ...` or newer. A version older than 1.26 is too old and the build step will refuse right away; install a newer Go and come back.

Now build the server program:

```sh
go build -o meshserver ./cmd/meshserver
```

A successful build **prints nothing at all**. Check the result with:

```sh
ls -la meshserver
```

You should see a file named `meshserver`, about 17 MB in size, with execute permission. That single file is the entire server program.

## 4. Step 2 — Create invite codes

An **invite code** is a secret string that acts as a single-use password: a brand-new device may register on your server only if it presents an invite code nobody has used yet. Each new device needs its own code.

The following command creates one random invite code:

```sh
openssl rand -hex 16
```

The result is one line of 32 hexadecimal characters, for example `3ab8178e7a0828689f420071a602d74f`. Run the command a few times so you have several codes ready (one per computer you plan to use), and store them somewhere safe, the way you keep passwords.

## 5. Step 3 — Write the configuration file

The server reads all of its configuration from one small JSON file named `config.json`. This step creates that file inside the `mesh-server` folder.

Create `config.json` with the following content, replacing the placeholders with the invite codes you just generated (list as many codes as you have, separated by commas):

```json
{
  "listen": "0.0.0.0:8734",
  "data_dir": "./data",
  "invites": ["paste-your-first-invite-code-here", "paste-your-second-invite-code-here"]
}
```

The three fields mean the following:

- `listen` is the address and port the server listens on. The value `"0.0.0.0:8734"` means "accept connections on every network address of this machine, on port 8734" — this is the right choice when other computers connect to the server directly (computers on the same home network, or a VPS with nothing in front of it). The value `"127.0.0.1:8734"` means "accept connections from this machine only" — use it only when another program on the same machine receives the outside connections and passes them in, as in the Caddy setup in step 7, or when you are only test-running on one machine.
- `data_dir` is the folder holding all of the server's data (the device list, the used invite codes, the approved pairings). It is created automatically the first time the server runs.
- `invites` is the list of invite codes you seed. The server loads this list at every startup; a code that has been used stays used and never comes back to life.

If you skip the configuration file and run the server anyway, the program falls back to defaults: it listens on the same machine only (`127.0.0.1:8734`) and has **no invite codes at all**, which means no new device can ever register. The configuration file is therefore required for real use.

## 6. Step 4 — First test run and checks

This step runs the server in the foreground, visible in your terminal, so you can see it start correctly before setting it up to run permanently in the background.

Run this command inside the `mesh-server` folder:

```sh
./meshserver -config config.json
```

A correctly started server prints one JSON log line containing `"msg":"mesh server listening"` together with the address you configured, and the terminal cursor stays there (the program is running, not finished). Leave this window as it is.

Open a second terminal window and check that the server is alive:

```sh
curl http://127.0.0.1:8734/healthz
```

The correct result is exactly this line:

```json
{"status":"ok"}
```

Next, also check that another computer can reach the server, because the app depends on it. On the machine running the server, find its local network IP address (on Linux use `hostname -I`, on macOS use `ipconfig getifaddr en0`). Then, from a different computer on the same network, run:

```sh
curl http://192.168.1.10:8734/healthz
```

(replacing `192.168.1.10` with the address you just found). If you still receive `{"status":"ok"}`, the network path is open. If the command hangs or reports it cannot connect, the usual cause is a firewall on the server machine not yet allowing port 8734 — see the troubleshooting section at the end of this guide.

When the checks are done, return to the first terminal window and press `Ctrl+C` to stop the test run.

## 7. Step 5 — Run the server permanently in the background

Once the test run works, you should run the server as a **background service** (a program that starts together with the machine and restarts itself if it ever stops unexpectedly), instead of keeping a terminal window open forever. Pick the part matching the operating system of the machine running the server.

### 7a. On Linux: using systemd

**systemd** is the service manager built into most Linux distributions (Ubuntu, Debian, and others). The commands below place the program and the configuration into `/opt/meshserver`, create a dedicated non-administrator account to run the service under (so that if the program ever has a problem, it is not running with the machine's highest privileges), and register the service.

From the `mesh-server` folder where you built the program, run these in order:

```sh
sudo mkdir -p /opt/meshserver
sudo cp meshserver config.json /opt/meshserver/
sudo adduser --system --group --home /opt/meshserver meshserver
sudo chown -R meshserver:meshserver /opt/meshserver
```

In these commands, the `meshserver` account is created only to run this service. The `./data` folder from your configuration will live at `/opt/meshserver/data`, because the service is configured to work from `/opt/meshserver` (the `WorkingDirectory` line in the service file below).

Next, create the service description file with a text editor:

```sh
sudo nano /etc/systemd/system/meshserver.service
```

Paste in the following content, save, and exit:

```ini
[Unit]
Description=MacViewer Ventura mesh server (Mode 2 self-hosted)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=meshserver
WorkingDirectory=/opt/meshserver
ExecStart=/opt/meshserver/meshserver -config /opt/meshserver/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Register and start the service:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now meshserver
```

A successful second command prints a line like `Created symlink ...`, telling you the service is now set to start with the machine. Check the service status:

```sh
systemctl status meshserver
```

The correct result contains the line `Active: active (running)`. Double-check with the familiar health command:

```sh
curl http://127.0.0.1:8734/healthz
```

It must still answer `{"status":"ok"}`. From here on, the two commands you will use most are `sudo systemctl restart meshserver` (restart after changing the configuration) and `journalctl -u meshserver -f` (watch the log live; press `Ctrl+C` to leave the log view — the server keeps running).

### 7b. On macOS: using launchd

**launchd** is macOS's built-in service manager, the equivalent of systemd on Linux. The steps below place the program into a `~/meshserver` folder inside your own account (no administrator rights needed) and register a user service that runs when you log in.

From the `mesh-server` folder where you built the program, run:

```sh
mkdir -p ~/meshserver
cp meshserver config.json ~/meshserver/
```

Create the service description file at `~/Library/LaunchAgents/dev.macviewer.meshserver.plist` with the following content. Replace `yourname` with your macOS account name (run `whoami` if you are not sure), because launchd does not understand the `~` character inside this file:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.macviewer.meshserver</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/yourname/meshserver/meshserver</string>
		<string>-config</string>
		<string>/Users/yourname/meshserver/config.json</string>
	</array>
	<key>WorkingDirectory</key>
	<string>/Users/yourname/meshserver</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/Users/yourname/meshserver/server.log</string>
	<key>StandardErrorPath</key>
	<string>/Users/yourname/meshserver/server.log</string>
</dict>
</plist>
```

Load the service and check it:

```sh
launchctl load ~/Library/LaunchAgents/dev.macviewer.meshserver.plist
curl http://127.0.0.1:8734/healthz
```

Receiving `{"status":"ok"}` means the service is running. The server's log is in the file `~/meshserver/server.log`. To stop the service, run `launchctl unload ~/Library/LaunchAgents/dev.macviewer.meshserver.plist`.

## 8. Step 6 — Opening the way in from outside, and HTTPS for Internet use

If both computers and the server are all on the same home network, you do not need this step: an address like `http://192.168.1.10:8734` is enough, and using unencrypted HTTP inside your own home network is a practical, acceptable choice.

If the server sits on a VPS, or you want to connect from out on the Internet, two more things are needed:

**Open the port on the firewall.** A **firewall** is the layer that controls which of the machine's ports may receive connections from outside. On an Ubuntu VPS with `ufw` enabled, open the port with:

```sh
sudo ufw allow 8734/tcp
```

Many VPS providers also have their own firewall layer in their management web page (often called a "security group" or "firewall rules") — open TCP port 8734 there too. If the server is a computer at home, open your router's administration page and create a **port forwarding** rule: forward external TCP port 8734 to the local IP address of the machine running the server, and give that machine a fixed local IP address in the router's DHCP settings, so its address does not change after a restart.

**Put the server behind HTTPS with Caddy.** When connections travel over the Internet, the path should be encrypted. The neatest way is **Caddy** — a program that acts as a **reverse proxy**: it stands in front of the Mesh server, receives encrypted HTTPS connections from outside (with a certificate it obtains automatically — you do not buy or configure one by hand), and passes them on to the Mesh server running on the same machine. The conditions: you own a domain name (for example `mesh.example.com`) whose DNS record points at your VPS's IP address, and ports 80 and 443 are open on the firewall.

Install Caddy following the official instructions at https://caddyserver.com/docs/install, then adjust the Mesh server's configuration: change `listen` in `config.json` back to `"127.0.0.1:8734"` (so that from outside, only Caddy can reach the server and nothing bypasses the encryption layer) and restart the Mesh service. Create the file `/etc/caddy/Caddyfile` with this content:

```
mesh.example.com {
	reverse_proxy 127.0.0.1:8734
}
```

(replacing `mesh.example.com` with your own domain). Restart Caddy with `sudo systemctl restart caddy`, then check from any computer on the Internet:

```sh
curl https://mesh.example.com/healthz
```

Receiving `{"status":"ok"}` means the whole chain works. From now on, the server address you enter into the app is `https://mesh.example.com` (no port needed, because HTTPS uses port 443 by default and Caddy handles the rest).

One 5.0 limitation you should know about up front: **the picture and the control connection only work when the two computers can reach each other directly** — on the same local network, or joined into one virtual private network (VPN) that makes them "see" each other as if they were on the same network. When the two computers are on two different home networks talking over the public Internet, the home routers at both ends usually block this direct path; the standard solution is a **TURN** server (a fallback relay for the picture traffic when the direct path fails). Version 5.0 does not include TURN yet, and a TURN guide will follow. In the meantime, pairing and chat keep working normally over the Internet, because they travel through your Mesh server and do not need the direct path.

## 9. Step 7 — Connect the app to your server

Do the following on each computer you want to use Mode 2 with.

**Enter the server address.** Open MacViewer Ventura, go to Settings, find the self-hosted server section, and enter your server's address into the "Server address" field. Type it in the form you built: `http://192.168.1.10:8734` for home-network use, or `https://mesh.example.com` if you placed the server behind Caddy. If you leave this field empty, the app uses a built-in default address — that is not your server, so when self-hosting, always fill in your own. The change takes effect the next time Mode 2 connects.

**Register the device.** Switch the main window to the "Self-hosted" mode. The first time, the app asks you for an **invite code**: enter one unused code from your configuration file. The correct result: the "This device" card shows your machine's Mesh ID (9 digits, grouped 3-3-3) and a connected status to the server. If the code is wrong or already used, the server refuses it (it answers with error 403, "a valid invite code is required") and the app reports that registration failed — see the troubleshooting section. Note that an invite code is needed only for a device's very first registration; the same device registering again gets its same Mesh ID back with no new code. But if you reinstall the app from scratch (the device creates a new key), it counts as a new device and needs a fresh invite code.

**Pair the two computers.** Repeat the two steps above on the second computer, with the exact same server address and a different invite code of its own. Then, on the first computer, enter the second computer's Mesh ID into the connect-by-Mesh-ID box and send the pairing request. On the second computer (with its app open), the request appears; approve it. The correct result: the second computer shows up in the first computer's paired devices list, and vice versa. Pairings **belong to the server that approved them**: if you later point the app at a different server, you will pair again from scratch on that server; pairings from the old server do not follow you.

**Start a control session.** Press the "Connect" button next to the paired device. The other computer receives a consent prompt naming your device and its Mesh ID; when the person there accepts, the session starts and you see their screen. On the same local network, the path badge in the session window shows **"Direct"** — the picture travels straight between the two computers. A **"Relay"** badge means the picture is detouring through a TURN server; as explained in step 6, version 5.0 does not configure TURN, so in practice you will only see "Direct".

## 10. Day-to-day operation

- **Backups.** The server's entire state lives in the `data_dir` folder (the `mesh.db` file inside it). To back it up, stop the service first, copy the whole data folder somewhere safe, then start the service again. Stopping first keeps the copy consistent, because while running the server also keeps two companion files (`mesh.db-wal` and `mesh.db-shm`) next to the database.
- **Adding invite codes.** Generate new codes with the command in step 2, add them to the `invites` list in the configuration file your service actually uses, then restart the service (`sudo systemctl restart meshserver` on Linux, or `launchctl unload` followed by `launchctl load` as in step 7b on macOS). A code that has already been used stays used after a restart; there is no way to "refresh" a code that was given to another device.
- **Quick health check.** At any time, `curl http://127.0.0.1:8734/healthz` (or through your public address) answering `{"status":"ok"}` means the server is alive.
- **Updating.** When a new version arrives: download the new source, build again as in step 1, stop the service, replace the old `meshserver` file with the new one, and start the service again. The configuration file and the data folder stay untouched; there is nothing to redo.
- **The server cleans up old data by itself.** Each session leaves only one metadata row (the pair of devices and the start time), and the server deletes rows older than 30 days at every startup. There is nothing to clean by hand.

## 11. Troubleshooting

| Symptom | Common cause | How to check and fix |
|---|---|---|
| The app cannot connect to the server; registration fails immediately | Wrong address or port; the server is not running; `listen` is `127.0.0.1` while the app is on another machine; the firewall blocks port 8734 | Run `curl http://<your-server-address>:8734/healthz` right on the machine running the app. If you do not get `{"status":"ok"}`, the problem is in the network path or the server, not the app. Check that the service is running, that `listen` matches your intention, and that the port is open on the firewall. |
| An invite code is refused | The code was already used by another device; a character was typed wrong; the service is reading a different configuration file or data folder than the one you just edited | Generate a completely new code, add it to the exact `config.json` your service uses, restart the service, and try again. Remember that a used code can never be used again, not even after restarting the server. |
| The other device shows as "offline" | The app on the other side is not open; the other side registered on a different server (a different address); the other machine is asleep | Open the app on both ends and compare the "Server address" fields — they must be identical. A device is only "online" while its app is open and connected to the server. |
| A pairing request never arrives | The other side's app is not open (requests are kept by the server and only appear when the other app is open and online; the app checks for new requests about every 20 seconds); a wrong Mesh ID was typed; the two computers registered on two different servers | Double-check all 9 digits of the Mesh ID, open the app on the other computer, and wait up to about half a minute. |
| The session connects but there is no picture, or the screen is black | The controlled computer (the host) has not granted MacViewer the Screen Recording permission; control additionally needs the Accessibility permission | On the controlled Mac: open System Settings → Privacy & Security → Screen Recording and enable MacViewer Ventura; open the Accessibility section and enable it there too if you need control. After granting permissions, reopen the app. The host must also be awake and unlocked. |
| Chat works, but screen/control will not connect when the two computers are on different networks | The picture needs a direct path between the two computers; two home routers usually block that path, and version 5.0 has no TURN server yet | Put both computers on the same local network or into the same VPN and try again. Pairing and chat keep working over the Internet because they travel through the Mesh server. |
| The path badge shows "Relay" instead of "Direct" | The picture is detouring through a TURN server instead of going straight | This is a status indication, not an error. "Direct" is the expected path when both computers share a network; "Relay" only appears once a TURN server has been configured (a TURN guide will follow). Either way, the picture never passes through the Mesh server. |

## 12. Security notes

- **Secret keys never leave the device.** On a Mac, the device's key is kept in the Keychain. The server receives and stores only the public key — the part that exists to be shared.
- **What the server stores:** each device's public key and name, the list of approved pairings, the used state of each invite code, and one metadata row per session (the pair of devices and the start time), deleted automatically after 30 days. The server does not store pictures and does not store control content.
- **Anyone who knows your server address and holds a still-valid invite code can register a new device.** Treat invite codes like passwords: do not post them publicly and do not send them over channels you do not trust. If you suspect an unused code has leaked, remove that code from the configuration file and restart the service — the code stops working.
- **When the server is reachable from the Internet, put it behind HTTPS** as in the Caddy setup in step 6, so that addresses, invite codes, and chat messages do not travel in readable form over the wire.
- **Only give invite codes to people you trust.** A paired person still has to be approved by you for each session in the consent prompt, but chat messages pass through your server — think of the Mesh server as a shared room for people who know each other.
