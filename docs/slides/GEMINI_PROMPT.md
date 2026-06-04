# Script prompts cho Gemini soạn văn trình bày UniTrack

Anh paste từng phần vào Gemini (Pro tốt nhất, vì context dài). Mỗi prompt
độc lập — chạy xong 1 phần, copy output, qua phần kế.

Nếu Gemini có **chế độ "Long context" / Gemini 1.5 Pro 1M token**: paste
hết 11 file slide + Q&A vào 1 lần, dùng prompt **#0 (combined)** thay vì
chạy từng prompt nhỏ.

---

## #0 — Prompt combined (recommended nếu Gemini hỗ trợ long context)

```
Bạn là chuyên gia thuyết trình kỹ thuật, đang chuẩn bị giúp tôi
nói trước team mobile của FPT Telecom (audience: dev iOS / Android /
Flutter, tech lead, PM analytics).

Tôi sắp trình bày 20 phút về SDK "UniTrack" — một analytics SDK
multi-platform do team tôi xây dựng, mục tiêu thay thế cho cách
team FPT Life đang dùng riêng từng SDK Snowplow + Firebase qua
folder FLifeTracker hardcode.

Mục tiêu thuyết trình:
1. Thuyết phục team chấp nhận migrate sang UniTrack
2. Giải đáp lo ngại (effort migration, risk, vendor lock-in)
3. Tạo niềm tin (đã có 4 demo app live, đã đo performance)

Tôi gửi bạn 11 file Markdown bên dưới (10 slides + 1 Q&A đầy đủ).
Yêu cầu bạn xuất ra:

A. **Script nói cho từng slide** (đoạn 1-2 phút mỗi slide, tổng 20
   phút). Văn nói tự nhiên, không đọc bullet point khô khan. Dùng
   "mình", "chúng ta", "team", tránh "tôi" cứng nhắc. Mỗi slide gồm:
   - Câu mở đầu hook
   - Nội dung chính (3-5 ý)
   - Câu chuyển slide

B. **Bảng Q&A handling**: từ file Q&A.md, viết lại 25 câu trả lời
   theo VĂN NÓI (không phải markdown khô). Mỗi câu:
   - "Câu hỏi: ..."
   - "Cách trả lời ngắn (30s): ..."
   - "Nếu họ hỏi tiếp deeper, nói thêm: ..."
   - "Nếu họ tỏ ra nghi ngờ / không tin: trả lời như sau: ..."

C. **Phần backup phòng khi audience im lặng**: 5 câu hỏi tự đặt cho
   audience để khuấy động (vd: "ai trong phòng đã từng debug session
   user mà không biết click button gì trước đó?")

D. **Closing 1 phút**: gọn, cảm xúc, push tới action point cụ thể
   ("ai muốn tham gia pilot tích hợp UniTrack vào Life sprint tới
   thì raise hand").

Quy tắc văn phong:
- Tiếng Việt tự nhiên, không lai-căng
- Cho phép dùng từ tiếng Anh kỹ thuật khi không có từ Việt tương
  đương (SDK, schema, queue, provider, fan-out)
- Tránh "rất", "thật sự" lặp đi lặp lại
- Không dùng emoji trong text nói (chỉ giữ ở slide visual)
- Số liệu phải khớp đúng với slide (200 review-hours, 31MB, 4 demo
  apps, 6 convention kinds, 30 events sheet)

[paste 11 file ở đây — 01-the-problem.md ... Q&A.md]
```

---

## #1 — Prompt riêng cho phần A (script nói)

Nếu Gemini không nhận long context, chạy riêng. Paste từng 2-3 slide
một lần.

```
Tôi đang chuẩn bị bài thuyết trình về SDK "UniTrack" cho team mobile
FPT Telecom. Audience: dev iOS / Android / Flutter, tech lead, PM.

Tôi gửi bạn 3 slide Markdown bên dưới. Hãy viết script tôi nói cho
mỗi slide, 1-2 phút mỗi slide, tổng 4-5 phút.

Yêu cầu văn nói:
- Tiếng Việt tự nhiên (không lai-căng)
- Dùng "mình", "chúng ta", "team"
- Hook mở đầu mỗi slide để audience chú ý
- 3-5 ý chính, không đọc bullet khô
- Câu chuyển sang slide kế
- Cho dùng từ kỹ thuật tiếng Anh khi cần (SDK, schema, provider, queue)
- Không emoji trong text nói

Sau script, viết "**Cue note**:" 1-2 dòng nhắc tôi khi nào đổi tone
(vd: "chậm lại ở đây", "show ví dụ code trên màn hình").

Slide content:

[paste 01-the-problem.md, 02-the-vision.md, 03-architecture.md]
```

Lặp lại với:
- Lần 2: paste `04-what-we-auto-capture.md` + `05-how-tap-works.md` + `06-fan-out-providers.md`
- Lần 3: paste `07-portal-and-insights.md` + `08-remote-config-power.md`
- Lần 4: paste `09-real-results.md` + `10-roadmap.md`

---

## #2 — Prompt cho phần B (Q&A handling — văn nói)

```
Tôi sắp Q&A 10 phút sau khi trình bày UniTrack SDK. Audience là dev
iOS / Android / Flutter / tech lead / PM analytics ở FPT Telecom.
Câu hỏi có thể đến từ góc skeptical ("không cần dùng đâu, FLifeTracker
đang ổn") hoặc deep technical.

Tôi gửi file Q&A.md (25 câu hỏi + trả lời text). Hãy chuyển từng câu
thành phiên bản nói trực tiếp với cấu trúc:

---
**Câu X**: [câu hỏi y nguyên]

**Trả lời ngắn (30 giây)**:
[1-2 câu trả lời cốt lõi, văn nói, không markdown table]

**Nếu họ hỏi deeper**:
[2-3 câu mở rộng, kèm 1 ví dụ cụ thể]

**Nếu họ tỏ ra nghi ngờ / không tin / đẩy ngược lại**:
[câu phản biện tôn trọng, dùng số liệu từ slide / Q&A để chứng minh]

**Cue note**: [khi nào nên show portal demo / khi nào nên thừa nhận
limitation / khi nào nên defer "sẽ làm Q2 2026"]
---

Quy tắc:
- Tiếng Việt nói tự nhiên
- Không né tránh câu khó — Q23, Q24, Q25 là "nhược điểm / risk", cần
  trả lời thẳng thắn, không sales pitch
- Số liệu phải khớp Q&A.md gốc

[paste Q&A.md]
```

---

## #3 — Prompt cho phần C (câu hỏi tự đặt để khuấy động)

```
Tôi sắp trình bày 20 phút về UniTrack SDK rồi Q&A. Audience FPT
Telecom mobile team. Soạn cho tôi 5 câu hỏi tôi tự đặt cho audience
để khuấy động khi:

1. Sau slide 1 (vấn đề FLifeTracker) — câu pull họ vào nỗi đau
2. Sau slide 5 (convention layer) — câu khiến họ tự suy ra lợi ích
3. Sau slide 7 (portal IDE) — câu khiến họ liên hệ tới case debug
   thực tế họ từng gặp
4. Sau slide 9 (kết quả) — câu mời họ commit thử
5. Cuối Q&A (nếu audience im) — câu provoke để có người raise hand

Mỗi câu kèm:
- Câu chính (1 câu, ngắn)
- Backup câu phụ nếu audience không phản hồi
- Câu chốt sau khi vài người trả lời

Quy tắc:
- Tiếng Việt tự nhiên
- Câu hỏi MỞ (không yes/no)
- Không sáo rỗng ("ai đã từng…" nhưng cụ thể, vd: "ai trong tuần
  vừa rồi đã phải debug một crash mà không có stack trace?")
- Tôn trọng audience — không patronize
```

---

## #4 — Prompt cho phần D (closing 1 phút)

```
Soạn cho tôi đoạn closing 1 phút (~150-180 từ) cho bài trình bày
UniTrack SDK. Đoạn này tôi nói cuối Q&A.

Mục tiêu:
1. Tóm tắt nhanh 3 lợi ích lớn nhất (vài giây)
2. Thừa nhận thẳng UniTrack chưa hoàn hảo (xem slide 10 roadmap)
3. Push tới action point CỤ THỂ:
   - Ai muốn tham gia pilot tích hợp vào Life sprint tới: raise hand
   - Hoặc DM tôi sau buổi này

Yêu cầu văn phong:
- Cảm xúc nhưng không sến
- Thẳng thắn (không bán hàng quá đà)
- Dùng "mình", "chúng ta"
- Kết bằng 1 câu để lại dư âm (không cliché kiểu "cảm ơn các bạn
  đã lắng nghe" — nói cái gì đó họ nhớ)
```

---

## #5 — Prompt rút gọn (nếu Gemini Free tier giới hạn)

Nếu anh dùng Gemini Free và bị cap context, dùng prompt này — chỉ
cần gen mỗi lần 1 slide:

```
Tôi đang trình bày SDK "UniTrack" cho team mobile FPT Telecom.
Slide N (dán bên dưới) — viết cho tôi:

1. Script nói 1-1.5 phút (văn Việt tự nhiên, dùng "mình"/"chúng ta")
2. Hook mở đầu + câu chuyển slide kế
3. Cue note 1 dòng

Slide content:
[paste 1 slide]
```

---

## Tips dùng Gemini cho task này

| Tip | Lý do |
|---|---|
| **Dùng Gemini Pro / 1.5 Pro / 2.0** | Văn nói cần độ tinh tế; Flash hay generic |
| **Bật "Long context" nếu có** | 11 file = ~50K token, cần model nhận long input |
| **Yêu cầu output dạng Markdown** | Anh dễ copy ra Keynote / slide notes |
| **Nếu output quá khô**: prompt thêm "tự nhiên hơn, đỡ formal đi" | Gemini default hơi cứng |
| **Iterate 2-3 vòng** mỗi slide | Lần 1 = base, lần 2 = "đoạn X dùng từ Y thay vì Z", lần 3 = polish |
| **Tránh paste ảnh slide** | Markdown đủ; ảnh tốn tokens, không thêm value |

---

## Workflow đề xuất

```
Bước 1: Mở Gemini 1.5/2.0 Pro
Bước 2: Paste prompt #0 (combined) + 11 file MD
        → Output: script + Q&A handling + 5 câu provoke + closing
Bước 3: Đọc qua output, mark đoạn nào cần sửa
Bước 4: Iterate từng phần
        - "Slide 3 chỗ giải thích C++ core đang khô, viết lại với 1 ví dụ cụ thể"
        - "Câu Q15 (cost) đang dài, gọn lại 2 câu"
        - "Closing thêm 1 câu kêu gọi cụ thể cho dev iOS"
Bước 5: Lưu output cuối thành 1 file "speaker-notes.md"
        Khi present: mở 2 cửa sổ — slide bên trái, speaker-notes bên phải
Bước 6: Rehearse 1 lần trước gương / quay video
        - Đo thời gian (20 phút phần slide + 10 phút Q&A + closing)
        - Note chỗ bị vấp → bổ sung cue note
```

---

## File này dùng làm gì sau khi xong?

- Lưu lại làm template cho lần trình bày khác (đổi audience: external
  customer, internal CTO, dev conf...)
- Đưa cho team member khác nếu họ trình bày thay
- Đính kèm vào PR khi merge UniTrack vào FPT Life (reviewer thấy
  business case rõ ràng)

---

→ Slide deck: [README.md](README.md)
→ Q&A nguồn: [Q&A.md](Q&A.md)
