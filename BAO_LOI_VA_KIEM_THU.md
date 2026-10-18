# Báo lỗi & giúp kiểm thử

MacViewer Ventura là dự án nhỏ, không có đội kiểm thử riêng — mỗi báo cáo lỗi tốt của người dùng đều giúp bản sau ổn định hơn. Tài liệu này gồm hai phần: cách thử các tình huống hay sinh lỗi, và cách báo sao cho lỗi sửa được nhanh. Toàn bộ phần tiếng Việt ở trước, bản tiếng Anh ở sau.

## Ba phép thử đáng giá nhất

Các lỗi khó chịu nhất của phần mềm điều khiển từ xa thường chỉ lộ ra theo thời gian. Ba phép thử dưới đây phủ đúng những tình huống đó; nếu bạn có thời gian, chạy thử trên bản mới nhất rồi báo kết quả (kể cả khi không gặp lỗi — cho biết máy, macOS và thời lượng thử).

### 1. Thử để yên (idle)

1. Kết nối tới máy đích, để nguyên không đụng vào **20–30 phút**.
2. Quay lại: thử bấm chuột và gõ phím.
3. Ghi lại: còn kết nối không, hình còn chạy không, chuột/phím còn tác dụng không, và nếu mất điều khiển thì sau khoảng bao nhiêu phút.

### 2. Thử phiên dài màn hình bận

1. Kết nối tới máy đích đang có nhiều thay đổi trên màn hình (video, cuộn trang liên tục, hoặc một chương trình đang chạy việc).
2. Dùng liên tục **20–30 phút**, để ý độ trễ có tăng dần không.
3. Ghi lại: hình có trễ dần so với thực tế không, bấm chuột có chậm dần không, hay ổn định suốt phiên.

### 3. Thử nối lại

1. Đang kết nối thì bấm ngắt kết nối, rồi kết nối lại ngay.
2. Ghi lại: lần nối lại có mượt như lần đầu không, hay chậm ngay từ đầu.

## Khi chuột/phím bỗng không có tác dụng

Trước khi báo lỗi, thử nhanh hai cách này và cho biết kết quả trong báo cáo — kết quả giúp khoanh vùng nguyên nhân rất nhiều:

- **Tắt rồi bật lại quyền điều khiển (Control)** trong cửa sổ phiên. Nếu điều khiển sống lại, ghi rõ "tắt/bật Control thì được".
- **Ngắt kết nối và kết nối lại.** Nếu vẫn chậm ngay từ đầu, ghi rõ "nối lại vẫn chậm từ đầu".

Và nhớ chụp hoặc ghi lại **nguyên văn thông báo trên màn hình** nếu có.

## Báo lỗi ở đâu, ghi những gì

Mở [issue mới](https://github.com/ArtyormSatori/MacViewer-Ventura/issues/new/choose) và chọn mẫu **Báo lỗi** — mẫu đã có sẵn các mục cần thiết: phiên bản app, macOS và chip, vai Viewer hay Host, triệu chứng, kết nối bao lâu thì gặp, lúc đó hình còn chạy hay đứng, nối lại thì thế nào, và các bước gây ra lỗi.

Ba nguyên tắc:

- **Một lỗi một issue** — đừng gộp nhiều lỗi vào một bài.
- **Đừng đăng mật khẩu hay ID đầy đủ của đối tác** — issue là công khai; che bớt vài số nếu cần nhắc tới.
- Nói rõ **thời lượng**: "dùng 5 phút" và "để yên 30 phút" là hai lỗi khác nhau, cách sửa khác nhau.

Đề xuất tính năng cũng mở qua cùng trang, chọn mẫu **Đề xuất tính năng**.

---

# Reporting bugs & helping test

MacViewer Ventura is a small project with no dedicated QA team — every good bug report makes the next release more stable. This document has two parts: how to test the situations that usually produce bugs, and how to report them so they can be fixed quickly. The full Vietnamese part comes first, this English part second.

## The three most valuable tests

The nastiest remote-control bugs only appear over time. These three tests cover exactly those situations; if you have time, run them on the latest release and report the outcome (even if nothing went wrong — include your machine, macOS version, and how long you tested).

### 1. Idle test

1. Connect to the target machine and leave everything untouched for **20–30 minutes**.
2. Come back and try clicking and typing.
3. Note: is it still connected, is the picture still moving, does input still work — and if control was lost, after roughly how many minutes?

### 2. Long busy-screen session

1. Connect to a target whose screen changes a lot (video, continuous scrolling, or a program busy working).
2. Use it continuously for **20–30 minutes** and watch whether delay builds up.
3. Note: does the picture fall further behind real time, do clicks get slower, or does it stay stable all session?

### 3. Reconnect test

1. While connected, disconnect, then reconnect right away.
2. Note: is the new session as smooth as the first, or slow from the very start?

## When mouse/keyboard suddenly has no effect

Before reporting, quickly try these two things and include the result in your report — it narrows down the cause a lot:

- **Toggle Control off and back on** in the session window. If control comes back, write "toggling Control fixed it".
- **Disconnect and reconnect.** If it is still slow from the start, write "reconnect still slow from the start".

And capture the **exact on-screen message** if there is one.

## Where to report, and what to include

Open a [new issue](https://github.com/ArtyormSatori/MacViewer-Ventura/issues/new/choose) and pick the **Bug report** template — it asks for everything needed: app version, macOS and chip, Viewer or Host role, symptom, how long you were connected before it happened, whether the picture was still moving, what reconnecting did, and the steps to reproduce.

Three rules:

- **One bug per issue** — do not bundle several bugs into one report.
- **Never post passwords or a partner's full ID** — issues are public; mask a few digits if you must mention one.
- State the **duration**: "used it for 5 minutes" and "left it idle for 30 minutes" are different bugs with different fixes.

Feature requests go through the same page with the **Feature request** template.
