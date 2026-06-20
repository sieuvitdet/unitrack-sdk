# UniTrack — Slide Deck (10 slides + Q&A)

Bài trình bày tích hợp UniTrack vào **FPT Life** (so sánh với
`FPTLife/FLifeTracker` hiện tại). Mỗi slide là 1 file `.md` — đọc xuôi
tạo thành 1 bài trình bày dài ~20 phút.

| # | File | Nội dung |
|---|---|---|
| 01 | [01-the-problem.md](01-the-problem.md) | FPT Life: 5 file/event, 200 review-hours/quarter, không auto-capture |
| 02 | [02-the-vision.md](02-the-vision.md) | 3 mục tiêu cốt lõi (4 platform / triển khai nhanh / Firebase Analytics only); 3 dòng init = 30 events |
| 03 | [03-architecture.md](03-architecture.md) | C++ core + 4 binding mỏng + portal Node.js; convention layer |
| 04 | [04-what-we-auto-capture.md](04-what-we-auto-capture.md) | 6 loại auto-capture: click / screen / network / crash recovery / lifecycle |
| 05 | [05-how-tap-works.md](05-how-tap-works.md) | Convention layer: 6 schema cho 30+ business events; vs FLifeTracker 30 schema |
| 06 | [06-fan-out-providers.md](06-fan-out-providers.md) | Fan-out: 1 event → Snowplow + Firebase Analytics + portal, không if-else 2 lần |
| 07 | [07-portal-and-insights.md](07-portal-and-insights.md) | Portal: session IDE thay Snowplow Console + Firebase + Sentry trong 1 |
| 08 | [08-remote-config-power.md](08-remote-config-power.md) | Đổi tên event / tắt auto-tap / export-import config bundle — không build app |
| 09 | [09-real-results.md](09-real-results.md) | 4 demo apps live: iOS / Android / Flutter / RN; 30 events mapping sheet |
| 10 | [10-roadmap.md](10-roadmap.md) | Đã làm Phase 1-3, roadmap Q1-Q4 2026, câu hỏi mở |
| | [Q&A.md](Q&A.md) | 25 câu hỏi thường gặp + trả lời ngắn (migration / kỹ thuật / vận hành / tương lai) |
| | [GEMINI_PROMPT.md](GEMINI_PROMPT.md) | Script prompt cho Gemini soạn văn nói + xử lý Q&A + closing |

## Cách trình bày
- **Đọc dưới dạng Markdown** trên VS Code / GitHub.
- **Convert ra PDF / Keynote**: dùng [Marp](https://marp.app/) — đã có frontmatter `marp: true` ở mỗi slide. Render slide-by-slide:
  ```bash
  npm install -g @marp-team/marp-cli
  marp docs/slides/*.md -o deck.pdf
  # hoặc HTML để present trên browser
  marp docs/slides/01-the-problem.md --html
  ```
- Q&A là tài liệu tra cứu, không cần convert slide; đọc trực tiếp khi nhận câu hỏi từ audience.
