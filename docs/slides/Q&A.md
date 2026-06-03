---
marp: true
theme: default
paginate: true
header: 'UniTrack · Q&A'
footer: 'Câu hỏi thường gặp khi tích hợp UniTrack'
---

# Q&A — Câu hỏi thường gặp về UniTrack

Tổng hợp câu hỏi từ team FPT Life + reviewer + dev khác. Mỗi câu kèm
trả lời ngắn (technical) + tham chiếu slide cụ thể.

---

## So với hiện trạng FLifeTracker

### Q1. UniTrack có thay được hoàn toàn FLifeTracker hiện tại không?

**Có.** Mapping 1-1:

| FLifeTracker | UniTrack |
|---|---|
| `AnalyticsManager.shared.track(.buttonClick(...))` | `snowplow.trackingClickEvent(elementKey:)` HOẶC auto-capture |
| `AnalyticsManager.shared.track(.screen(.cameraScreen))` | `UniTrack.setScreen(...)` (auto qua swizzler) |
| `AnalyticsManager.shared.track(.actionCustom(.play))` | `UniTrack.track("play_media", ...)` qua kind `result` |
| `AnalyticsManager.shared.track(.networkCustom(...))` | Auto-capture qua URLProtocol |
| `SnowplowAnalyticsProvider` | `SnowplowProvider` (UniTrack có sẵn) |
| `FirebaseAnalyticsProvider` | `FirebaseProvider` (UniTrack có sẵn) |

Migration path: chạy song song 1 release (UniTrack + FLifeTracker cũ),
verify portal nhận đúng event, drop FLifeTracker ở release tiếp.

---

### Q2. App size tăng bao nhiêu nếu thêm UniTrack?

| Platform | Overhead so với FLifeTracker hiện tại |
|---|---|
| iOS | +50KB Swift binary + C++ core ~120KB |
| Android | +80KB Kotlin DEX + JNI ~150KB |
| Flutter | +60KB Dart + native binding |
| RN | +80KB JS bundle minified |

C++ core dùng chung → cài thêm provider thứ 2/3 chỉ +20KB mỗi cái.

→ FLifeTracker hiện tại ~150KB (chỉ Swift wrapper); UniTrack ~250KB (full
SDK + core + queue + crash handler).

---

### Q3. Có ảnh hưởng performance cold-start không?

Đo trên iPhone 15 Pro release build:

- `UniTrack.initialize()` synchronous: **8-12ms** (mở SQLite + init queue)
- Config fetch async: không block UI, complete sau 200-400ms
- Track call: <1ms (in-memory enqueue + signal background thread)
- Flush background: không touch main thread

Cold start FPT Life hiện tại ~2.1s; UniTrack add ~0.5%.

---

### Q4. Snowplow tracker FLifeTracker đang dùng có giữ được không?

**Được.** `SnowplowProvider` của UniTrack **wrap** Snowplow SDK chính chủ
(`snowplow_tracker` 0.7+ trên Flutter, `SnowplowTracker` 6.x trên iOS).
Không thay engine, chỉ thay tầng app code → Snowplow wrapper.

Backend `ftracking.fpt.vn` collector không cần đổi gì. Iglu Registry vẫn
dùng cũ (chỉ cần 6 schema mới generic).

---

### Q5. Migration cũ → mới có rủi ro data gap không?

Strategy 3 bước:

1. **Phase A (1 sprint)**: Add UniTrack init song song FLifeTracker. Cả 2
   fire cùng event. Verify portal + Snowplow collector nhận đủ.
2. **Phase B (1 sprint)**: Convert UI call site dần — mỗi PR convert 1
   feature. Track diff count event giữa hai SDK.
3. **Phase C**: Drop FLifeTracker code. Drop direct Snowplow/Firebase
   import (UniTrack mang transitively).

Không có window data loss. Chi phí dual-fire 1 sprint = chấp nhận được.

---

## Kỹ thuật

### Q6. SDK có hoạt động khi mất mạng không?

**Có.** Core C++ persist event vào SQLite ngay khi `track()` gọi. Khi mạng
phục hồi, worker thread tự flush batch.

Default config:
- `batchSize`: 10 events / POST
- `flushIntervalMs`: 5000ms
- `maxQueueSize`: 1000 events (cũ hơn bị evict)
- `maxAgeDays`: 7 (event > 7 ngày drop)
- `maxRetries`: 3 per batch

Tất cả override qua portal `sdk_config`.

---

### Q7. App crash giữa session, event đang queue có mất không?

**Không.** Queue là SQLite WAL mode persist trên disk. Crash → file vẫn còn.
Lần mở sau, `ut_init` resume queue và tự flush.

Riêng event `crash` được signal handler ghi vào `crash-pending.json`
(separate file, async-signal-safe write). Lần mở sau, SDK đọc file →
emit `event_crash` với `recovered_on_launch: true` → fan-out các provider.

→ Crash log không bao giờ mất.

---

### Q8. Có hỗ trợ multi-thread track() không?

**Có.** `UniTrack.track()` thread-safe.
- Swift: `dispatch_queue` internal serial
- Kotlin: synchronized block + atomic counter
- Dart: `Future` async
- TS: JS single-threaded, không vấn đề

Track từ background thread an toàn. Provider tự lock state.

---

### Q9. Có support GDPR consent không?

**Partial.** SDK có `setEnabled(false)` để tắt toàn bộ tracking runtime.
Roadmap Q3 2026: thêm per-event consent flag (analytics / performance /
marketing).

Hiện tại app phải tự gating: nếu user chưa accept, KHÔNG gọi
`UniTrack.initialize()`. Khi nào accept thì init.

---

### Q10. Tracing W3C có integrate với backend trace gì không?

App fire `traceparent: 00-<trace_id>-<span_id>-01` header với mọi outbound
HTTP. Backend nginx/api-gateway nhận header → log cùng trace_id → portal có
thể grep cùng trace_id để correlate **client event ↔ server log**.

`allowlistHosts` fail-closed: empty list = không inject header, tránh leak
trace_id sang Firebase / Maps / CDN.

---

## Vận hành

### Q11. Ai quản portal? Hosted ở đâu?

Hiện tại self-hosted: VPS `103.188.83.49` (Singapore), Node.js 22 + SQLite,
nginx reverse proxy.

DB ~50KB sau 1000 events test. Scale tới 1M events/day cần migrate sang
PostgreSQL hoặc external (TimescaleDB).

Backup: cron `sqlite3 .backup` mỗi giờ, sync S3.

---

### Q12. Nếu portal down, app có break không?

**Không break.**
- Config fetch fail → app dùng cached config (UserDefaults / SharedPrefs)
- Init Snowplow direct → vẫn hoạt động vì Snowplow collector khác URL
- Init Firebase → vẫn hoạt động (Firebase không phụ thuộc portal)
- Track event → enqueue local, đợi portal up

App **chỉ mất tính năng remote config + portal session IDE**. Snowplow +
Firebase backend vẫn nhận event bình thường.

---

### Q13. Portal có dashboard cho non-tech viewer không?

Hiện tại: Sessions + Logs là dạng dev-friendly (filter, raw JSON).
Roadmap: tab **Activity** + **Funnel builder** UI cho PM/marketing.

Workaround hiện tại: PM xem qua tab **Sessions** filter theo screen/event
+ tab **Agent** (LLM tự summary session).

---

### Q14. Có tích hợp Sentry / Bugsnag không?

**Không có sẵn provider Sentry/Bugsnag.** Lý do:
- UniTrack đã có crash recovery + frame addresses → portal symbolicate được
- Snowplow + Firebase đủ cho hầu hết use case

Nếu cần Sentry: viết `SentryProvider: AnalyticsProvider` custom (~50 dòng).
SDK design open cho 3rd-party provider qua `UniTrack.addProvider(...)`.

---

### Q15. Cost compare với Snowplow self-hosted enterprise?

| Component | UniTrack | Snowplow Open Source | Snowplow BDP |
|---|---|---|---|
| Tracker SDK | Free (MIT roadmap) | Free | Free |
| Collector | Portal Node.js (free) | Scala (self-host AWS) | Managed |
| Iglu Registry | Embedded portal | Self-host | Managed |
| Pipeline | Direct DB write | Enrich → S3/BigQuery | Managed |
| Storage | SQLite local | BigQuery/Snowflake | Managed |
| Dashboard | Portal session IDE | Looker/Tableau | Snowplow Console |
| Cost/month | ~$10 VPS | ~$300 AWS infra | $$$$ |

→ UniTrack phù hợp scale **1-10M events/day**. Trên 100M cần migrate
backend sang Snowplow proper hoặc ClickHouse.

---

## Tương lai / mở rộng

### Q16. Có hỗ trợ Web (JavaScript browser)?

**Chưa.** Roadmap Q2 2026: `@unitrack/web` package.

Hiện tại web có thể dùng Snowplow JS tracker trực tiếp + portal nhận event
qua endpoint chung `/v1/events`. UniTrack convention layer chưa có cho JS.

---

### Q17. Có open-source không?

**Hiện tại private repo** (github.com/sieuvitdet/unitrack-sdk). Plan public
khi:
- API stable v1.0 (hiện 0.2.x)
- Documentation đầy đủ (đang viết)
- 1-2 customer ngoài FPT Telecom đã chạy production
- Legal review FPT IP

License dự kiến: Apache 2.0.

---

### Q18. Có dùng được cho app web embed (in-app browser)?

Có. UniTrack iOS swizzle `WKWebView.load()` → fire `webview_open` event tự
động. Nếu app open browser hệ thống (SFSafariViewController hoặc external
Safari) → fire `third_party_open(target: "browser")`.

Android + Flutter cần helper gọi tay (`UniTrack.attachToWebView(webView)`)
vì WebViewClient không có universal swizzle.

---

### Q19. Có thay được Mixpanel / Amplitude không?

Về mặt **event tracking** thì có.

Về **product analytics dashboard** (funnel, retention, cohort) hiện tại
**chưa**. Roadmap Q2 có funnel builder. Cohort + retention sẽ là Q4.

Nếu team đã quen Mixpanel: viết `MixpanelProvider: AnalyticsProvider`
custom, UniTrack fan-out song song. Best of both.

---

### Q20. Crash log có symbolicate được không?

**Hiện tại**: raw frame addresses, không có symbol.

**Cần làm thêm**:
1. App build release upload dSYM (iOS) / proguard map (Android) lên portal
2. Portal lưu mapping per-version
3. Khi nhận `event_crash` → lookup dSYM → translate address → human-readable stack

Tương đương Sentry/Crashlytics. Estimate 2 sprints.

---

### Q21. Tích hợp ML/AI insights được không?

Roadmap **Agent** tab có rồi:
- LLM (Claude/GPT) đọc session journey
- Output: "User bị stuck ở pairing screen 3 lần, có thể do button 'Retry' khó thấy"
- Action: tạo issue Linear/Jira tự động

Đã có MVP, đang refine prompt. Q1 2026 public beta.

---

### Q22. Backend nhận event format gì?

Portal ingest endpoint: `POST /v1/events`

```json
{
  "batch": [
    {
      "event_id": "uuid",
      "event_name": "event_click",
      "session_id": "...",
      "user_id": "...",
      "timestamp": 1780000000000,
      "screen": "CameraListScreen",
      "properties": { ... },
      "device": { "os": "iOS", "os_version": "...", "app_version": "..." }
    }
  ]
}
```

Standard JSON, chunk gzip optional. Authorization header `Bearer utk_…`.

→ Bất cứ backend nào parse JSON đều integrate được, không lock vào portal Node.js.

---

## Khi không nên dùng UniTrack

### Q23. UniTrack có nhược điểm gì?

Honest list:

1. **Project chỉ cần 1 provider duy nhất** (vd app chỉ dùng Firebase) → wrap qua UniTrack
   tạo thêm 1 lớp indirection không cần thiết. Direct Firebase tracker đơn giản hơn.

2. **App rất nhỏ** (App Clip iOS, Instant App Android) — 250KB overhead quá đáng kể.

3. **App có taxonomy event hoàn toàn khác** (không match 6 convention kinds) →
   phải dùng `trackingCustomEvent` cho mọi event → mất lợi ích convention layer.

4. **Realtime <100ms required** (vd game in-app event) → SDK batch 3s delay
   không phù hợp; cần track direct mode (chưa support).

5. **Compliance cực strict** (HIPAA, financial PCI) → SDK chưa có audit
   trail, cần verify thêm trước khi dùng cho app y tế/ngân hàng.

---

### Q24. Có vendor lock-in không?

**Thấp.**

- Event format: standard JSON, có thể export bất kỳ lúc nào
- Snowplow downstream vẫn nhận iglu standard schema
- Firebase downstream nhận standard logEvent
- Portal source code có thể fork (Node.js, không phụ thuộc cloud-specific)
- DB SQLite → migrate PostgreSQL/MySQL dễ
- SDK MIT/Apache (planned)

Nếu drop UniTrack: app vẫn fire Snowplow + Firebase trực tiếp (như
FLifeTracker hiện tại). Chỉ mất portal IDE + remote config.

---

### Q25. Risk gì lớn nhất?

**Bus factor**. SDK code 31MB, ~10K LOC, 1 contributor chính. Nếu primary
maintainer rời, không ai đủ context để fix nhanh các issue cross-platform
(C++ core + 4 binding language).

Mitigation:
- Documentation (slides này + handbook + code comments)
- Pair với 1 dev mỗi platform để spread knowledge
- Public open-source Q2 2026 → cộng đồng contribute
- CI tests cover regression (chưa đủ — Q1 2026 priority)

---

## Hết Q&A

Mọi câu hỏi khác → ping team UniTrack (Slack `#unitrack-sdk` hoặc email
`unitrack@fpt.com.vn`).
