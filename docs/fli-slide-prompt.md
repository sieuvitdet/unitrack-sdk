# Prompt redesign slide cho buổi trình bày FLI

Anh copy nguyên block dưới đây paste vào Claude (design mode), kèm file gốc `UniTrack Presentation.html` để Claude tham chiếu phong cách.

---

## Prompt

Anh có 1 slide deck cũ `UniTrack Presentation.html` (Soft UI style, light theme, font Poppins, palette pastel hồng/xanh dương/xanh lá). Anh cần em design lại slide mới dựa trên slide cũ này, **giữ nguyên phong cách Soft UI, palette, font, layout grid, animation transition**, chỉ thay đổi nội dung và một số slide theo các tiêu chí sau:

### Bối cảnh

- Audience: team kỹ thuật FPT Life FLI (iOS + Android + BE).
- UniTrack là analytics SDK đa nền tảng do anh tự build, hiện chạy production trên FPT Life iOS + Android.
- Hạ tầng quản lý cấu hình chưa ready ở phía công ty FPT, nên slide không được phép đề cập tới nó. App đang dùng file cấu hình JSON gắn cùng app bundle — đây là điểm xuất phát mặc định của SDK, không phải workaround tạm thời.

### Tiêu chí nội dung

**1. KHÔNG đề cập tới hạ tầng quản lý cấu hình tập trung của anh dưới bất kỳ hình thức nào.**
- Không nói "Portal", "mobix.asia", "dashboard cấu hình", "trang quản lý SDK", "config server".
- Không vẽ box/icon đại diện cho 1 hệ thống quản lý cấu hình bên cạnh app.
- Không có flow chart từ "Operator/Admin → save config → app pickup".

**2. KHÔNG đề cập tới chức năng cập nhật cấu hình realtime.**
- Không nói "SSE", "Server-Sent Events", "realtime config refresh", "live push", "stream config".
- Slide 3 (chức năng config stream) BỎ HẲN — thay bằng nội dung khác liên quan tới khả năng SDK.

**3. Trình bày cấu hình SDK theo hướng "SDK đọc file JSON".**
- Trình bày nó như một thiết kế chính thức của SDK, không phải fallback hay tạm thời.
- Không dùng các từ "fallback", "bundled config", "frozen mode", "hard JSON", "gắn JSON xong là chạy", "plug JSON in and go".
- Wording chuẩn nên dùng: "SDK cấu hình thông qua file JSON", "team app sở hữu file cấu hình", "thay đổi cấu hình bằng cập nhật file JSON và build lại".

**4. Giữ tinh thần "plug and play" nhưng đơn giản hơn.**
- Trong slide cũ tinh thần này có vẻ được nhấn mạnh nhiều — anh muốn giữ ý tưởng "tích hợp nhanh, ít cấu hình thủ công" nhưng nói gọn hơn, chỉ 1 slide hoặc 1 block trong slide tổng quan, không tách thành section riêng. Tránh khoe rườm rà.

### Tiêu chí phong cách văn

Anh có một cách viết riêng — slide trước đó dùng phong cách này khá tốt, em phải giữ:

- **Câu khẳng định ngắn, có sức nặng kỹ thuật.** Không dùng các câu nịnh hay buzzword marketing kiểu "powerful", "seamless experience", "next-gen analytics".
- **Tránh đỉnh cao "gắn vào — chạy ngay"** hoặc "1 dòng code, xong".  Đây là cách viết anh ghét. Trình bày kỹ thuật ra trông như nó có thiết kế đằng sau, không phải mánh khoé.
- **Mỗi bullet là 1 ý.** Không gộp 2-3 ý vào 1 dòng dài.
- **Không dùng emoji** trong nội dung slide (giữ icon SVG, illustration phẳng như slide cũ là OK).
- **Số liệu cụ thể nếu có** (vd "4 platform: iOS, Android, Flutter, React Native") thay vì nói chung chung ("multi-platform").
- **Tiếng Việt là ngôn ngữ chính.** Có thể giữ tên kỹ thuật bằng tiếng Anh (event, session, schema, SDK, JSON, ...).

### Tiêu chí thiết kế

- **Giữ nguyên** chỉ số tham chiếu visual của slide cũ: palette, font, kích thước canvas (1920x1080 hoặc tỷ lệ hiện tại), animation chuyển slide, layout block, soft shadow.
- **Giữ** illustration phẳng + icon SVG kiểu pastel.
- **Tổng số slide khoảng 10-12** sau khi gọn lại — không cần kéo dài hơn 12.
- **Slide tiêu đề** giữ logo "Uni**Track**" + tagline ngắn 1 dòng.

### Nội dung gợi ý cho từng slide (anh có thể điều chỉnh)

| # | Slide | Nội dung gợi ý |
|---|---|---|
| 1 | Title | UniTrack — analytics SDK cho app di động đa nền tảng |
| 2 | Vấn đề | Vì sao FPT Life cần 1 SDK analytics riêng (3-4 bullet vấn đề thực tế) |
| 3 | Giải pháp tổng quan | Kiến trúc 3 lớp: app code → SDK core → các provider downstream (Snowplow, Firebase, ingest endpoint). Mention nhẹ "tích hợp nhanh, ít cấu hình thủ công" ở 1 góc |
| 4 | 4 nền tảng | iOS / Android / Flutter / React Native — 1 codebase C++ core dùng chung |
| 5 | Auto-capture | Tap / screen / network bắt tự động không cần DEV viết code. Có thể tắt từng nhóm. |
| 6 | Custom event | DEV gọi helper domain (vd `streamStarted`, `pairingCompleted`) → mọi event ra cùng schema |
| 7 | Session attribution | 1 session_id duy nhất xuyên suốt — gắn vào mọi event để join được journey user |
| 8 | Offline resilience | SQLite queue + retry. Event không mất khi mất mạng. Kill detection bù session_ended sau force-quit |
| 9 | W3C trace context | Inject `traceparent` vào HTTP outbound → BE log + mobile event link được bằng trace_id |
| 10 | Cấu hình qua JSON | File JSON gắn trong app, mô tả: endpoint, provider, sampling, auto-capture toggle, trace allowlist. Thay đổi → update file → build lại |
| 11 | Tích hợp tại FPT Life | Hiện trạng: iOS SPM 0.3.46 + Android Maven 0.3.11, đã production. 18+ event helper FSDKTracking đã wire |
| 12 | Roadmap ngắn | 2-3 việc tiếp theo (vd nhúng Flutter co-resident, mở rộng providers...) |

### Output em mong đợi

- 1 file HTML standalone giống slide cũ (self-contained, mở trực tiếp trong trình duyệt là chạy).
- Animation chuyển slide bằng phím mũi tên hoặc click.
- Có thumbnail/preview slide đầu.
- Phong cách + palette + font khớp với slide cũ.

### File tham chiếu

- `UniTrack Presentation.html` — slide cũ, phong cách + style cần kế thừa.

Bắt đầu đi em. Sau khi xong show preview slide 1, 3, 10, 11 để anh review trước, rồi mới generate full deck.

---

## Notes cho anh khi review

Khi Claude design generate xong, anh check riêng:

1. **Có còn từ "Portal", "config stream", "SSE", "realtime config" không** — search Cmd+F trong file HTML output.
2. **Slide 3 cũ về config stream đã bỏ hoàn toàn chưa** — nội dung slide 3 mới phải là chủ đề khác (giải pháp tổng quan / kiến trúc).
3. **Wording "plug JSON", "gắn JSON xong là chạy"** không được xuất hiện — tinh thần plug-and-play chỉ nên là 1 bullet nhỏ trong slide tổng quan.
4. **Slide JSON config** (số 10) không được mô tả như fallback/workaround — phải present như thiết kế chính thức.
