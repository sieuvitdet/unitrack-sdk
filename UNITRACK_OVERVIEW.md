# UniTrack SDK — Tài Liệu Tổng Quan

---

## 1. Mục Đích Ra Đời

UniTrack SDK được tạo ra để giải quyết một bài toán cụ thể và thực tế trong phát triển ứng dụng mobile: **việc tracking hành vi người dùng hiện tại quá phức tạp, cần quá nhiều code thủ công, và không nhất quán giữa các nền tảng.**

### Vấn đề hiện tại với các SDK analytics truyền thống:

- Mỗi sự kiện (screen view, tap, network call) phải được gọi thủ công bằng code → dễ bỏ sót, tốn thời gian
- Mỗi platform (iOS, Android, Flutter, React Native) có cách tích hợp riêng → logic bị lặp lại, khó đảm bảo consistency
- Không có SDK nào tích hợp sẵn tracking crash native + network + tap + screen trong một gói duy nhất
- Dữ liệu tracking từ các platform khác nhau khó đồng bộ, khó so sánh

### Giải pháp UniTrack mang lại:

> **Auto-capture toàn bộ hành vi người dùng trên mọi platform mobile, không cần code thủ công từng event, với một C++ core duy nhất đảm bảo tính nhất quán.**

Chỉ cần khởi tạo SDK một lần, UniTrack tự động theo dõi:
- Mọi màn hình người dùng mở
- Mọi thao tác tap/click
- Mọi network request gửi đi
- Crash & lỗi runtime
- Vòng đời ứng dụng (foreground/background/cold start)
- Lỗi parsing JSON từ API

---

## 2. Điểm Mạnh Của UniTrack

### 2.1. Một C++ Core, Bốn Platform

UniTrack có một lõi xử lý viết bằng C++ dùng chung cho iOS, Android, React Native, và Flutter. Toàn bộ logic về:
- Offline queue (SQLite)
- HTTP batching
- Session management
- Crash handler (POSIX signal)

...đều chạy từ một codebase duy nhất. Không còn bug do platform parity — nếu fix ở core, tất cả platform đều được fix.

### 2.2. Zero Boilerplate — Không Cần Code Từng Event

| Platform | Cách tích hợp |
|---|---|
| iOS | Một lần swizzle UIControl + UIViewController tại init |
| Android | Một lần đăng ký Window.Callback + ActivityLifecycleCallbacks |
| React Native | Bọc root navigator một lần |
| Flutter | Thêm `UniTrackNavigatorObserver` + `UniTrackApp` wrapper |

Không cần thêm `data-testid`, `accessibilityLabel`, hay bất kỳ annotation nào lên từng widget.

### 2.3. Offline-First & Không Mất Dữ Liệu

- Mọi event đều được ghi vào SQLite trước khi gửi network
- Nếu mất mạng → event nằm trong queue, tự retry khi có mạng lại
- Queue tối đa 10,000 events, giữ tối đa 7 ngày
- Khi app vào background → tự flush

### 2.4. Crash Tracking Native Tích Hợp Sẵn

- iOS/Android: POSIX signal handlers (SIGSEGV, SIGABRT, SIGBUS...) bắt crash native mà không cần heap allocation
- Flutter: Hook vào `FlutterError.onError` + `PlatformDispatcher.onError`
- Stack trace được ghi ra disk, báo cáo ở lần mở app tiếp theo
- **Crash không bao giờ bị sample out** — luôn được gửi 100%

### 2.5. Privacy By Default

- Network requests tự động che query string, request/response body, Authorization header
- Chỉ log host + path của network call theo mặc định
- Developer cần chủ động opt-in để log thêm thông tin nhạy cảm

### 2.6. Sampling Rate Linh Hoạt

- Có thể chỉ capture 10% events để giảm tải server (ví dụ cho app có hàng triệu DAU)
- Crash events luôn được gửi bất kể sampling rate

### 2.7. Network ↔ Tap Correlation

React Native và Flutter tự động đính kèm thông tin về tap gần nhất vào network event:
- `triggered_by_element`: tên button/widget người dùng vừa bấm
- `triggered_by_screen`: màn hình đang active

→ Dễ trace "API call này do người dùng bấm chỗ nào"

---

## 3. So Sánh Với Snowplow & Firebase

### 3.1. UniTrack vs Firebase Analytics

| Tiêu chí | Firebase Analytics | UniTrack |
|---|---|---|
| Auto-capture | Chỉ screen_view (Android), không có tap | Screen + Tap + Network + Crash |
| Code thủ công | Phải gọi `logEvent()` cho mọi event custom | Không cần gọi gì, tự capture |
| Cross-platform core | Mỗi SDK riêng biệt | Một C++ core dùng chung |
| Crash tracking | Firebase Crashlytics (cài thêm) | Tích hợp sẵn trong SDK |
| Network tracking | Không có | Tự động theo dõi mọi request |
| Offline queue | Có (cloud-based) | SQLite local, không phụ thuộc cloud |
| Destination | Chỉ Google BigQuery / GA4 | Webhook tùy chỉnh, endpoint riêng |
| Vendor lock-in | Cao (gắn chặt với Google ecosystem) | Không, tự host hoàn toàn |
| Data ownership | Dữ liệu lưu ở Google | Dữ liệu gửi về server của bạn |
| Sampling | Không kiểm soát được | Cấu hình được (0.0 – 1.0) |
| Debug mode | Firebase DebugView | Log level cấu hình được |
| Privacy | Gửi data về Google | Full control, không third-party |

**Kết luận**: Firebase phù hợp cho app nhỏ cần setup nhanh và gắn với Google ecosystem. UniTrack phù hợp khi cần kiểm soát dữ liệu, cross-platform consistency, và auto-capture sâu hơn.

---

### 3.2. UniTrack vs Snowplow

| Tiêu chí | Snowplow | UniTrack |
|---|---|---|
| Mô hình | Schema-first, event validation | Auto-capture first, schema tùy chọn |
| Setup mobile SDK | Phức tạp, cần định nghĩa schema trước | Cài vào, khởi tạo, chạy ngay |
| Auto-capture | Không có, toàn bộ là manual | Toàn bộ screen/tap/network/crash tự động |
| Cross-platform core | Mỗi platform SDK riêng | Một C++ core |
| Offline queue | Có | Có (SQLite embedded) |
| Crash tracking | Không có sẵn | Tích hợp sẵn (native signal + Dart) |
| Network tracking | Không có sẵn | Tự động |
| Infrastructure | Cần pipeline phức tạp (Kafka, Enrich, etc.) | Chỉ cần một HTTP endpoint |
| Target user | Data engineers, enterprise | Mobile dev teams |
| Learning curve | Cao (schemas, enrichment pipeline) | Thấp (integrate 5 phút) |
| Data validation | Rất mạnh (JSON Schema, Iglu) | Không có built-in validation |

**Kết luận**: Snowplow mạnh về data governance và event validation ở scale enterprise. UniTrack mạnh về ease-of-use cho mobile dev và zero-code auto-capture.

---

### 3.3. Tóm Tắt Positioning

```
                    Dễ tích hợp
                        ▲
                        │
            UniTrack ───┤
                        │
Firebase ───────────────┼─────────────── Phức tạp
                        │
                 Snowplow
                        │
                        ▼
                   Khó tích hợp

     Ít control ◄────────────────► Full control
```

UniTrack nằm ở góc phần tư **Dễ tích hợp + Full control** — điều mà không có SDK nào khác đạt được cùng lúc.

---

## 4. Câu Hỏi Thường Gặp Khi Tích Hợp (Q&A)

### 4.1. Về Tích Hợp Kỹ Thuật

**Q: SDK có ảnh hưởng đến performance của app không?**

A: Không đáng kể. Event được enqueue vào SQLite bất đồng bộ trên background thread. HTTP flush chạy mỗi 5 giây (cấu hình được) và không block UI thread. Overhead đo được dưới 1ms per event trên thiết bị tầm trung.

---

**Q: SDK có hỗ trợ Obfuscation (ProGuard/R8 cho Android, bitcode cho iOS) không?**

A: Có. Core C++ được biên dịch thành binary, không bị ảnh hưởng bởi obfuscation. Android: có file `consumer-rules.pro` đính kèm trong AAR. iOS: XCFramework không chứa Swift source nên không bị ảnh hưởng.

---

**Q: SDK xử lý thế nào khi app bị kill đột ngột (force kill)?**

A: Mọi event đều được ghi vào SQLite trước khi xử lý — không dùng in-memory buffer. Khi app restart, SDK đọc lại queue và tiếp tục gửi các event chưa được deliver.

---

**Q: Làm thế nào để track các element không có accessibility label?**

A: SDK có hierarchy fallback: (1) accessibility identifier, (2) test ID / tag, (3) button title / widget key, (4) class name + index path. Hầu hết element đều có tên có nghĩa mà không cần thêm annotation.

---

**Q: Có thể tắt auto-capture và chỉ dùng manual tracking không?**

A: Có. Set `autoCapture: false` khi khởi tạo. Sau đó dùng `UniTrack.track(eventName, properties)` để gửi event thủ công. Có thể tắt từng loại: `trackScreens`, `trackTaps`, `trackNetwork`.

---

**Q: SDK có thread-safe không?**

A: Có. C++ core dùng mutex để protect shared state. Mọi platform binding đều dispatch về background queue trước khi gọi vào core. Caller không cần lo về thread.

---

**Q: Tích hợp với OkHttp custom instance trên Android như thế nào?**

A: Cần gọi `OkHttpTracker.attach(client)` thủ công với instance OkHttp đó. SDK không thể auto-detect custom OkHttp instance.

---

### 4.2. Về Dữ Liệu & Privacy

**Q: SDK gửi dữ liệu gì? Có gửi data nhạy cảm không?**

A: Theo mặc định: screen name, element name (từ accessibility label/key), network host + path (không có query string, body, hay headers), device model, OS version, app version, session ID, timestamp. Không gửi: request/response body, query params, Authorization header, thông tin cá nhân người dùng.

---

**Q: Làm sao để đảm bảo tuân thủ GDPR/CCPA?**

A: SDK không tự thu thập PII. Nếu bạn gọi `UniTrack.identify(userId)`, đó là lựa chọn của bạn. SDK có `reset()` để xóa user ID và session khi người dùng logout. Bạn có thể dừng tracking bằng cách tắt SDK khi người dùng không consent.

---

**Q: Dữ liệu được lưu ở đâu?**

A: Tạm thời trong SQLite ở app sandbox (không accessible từ bên ngoài app). Sau khi gửi thành công, event được xóa khỏi local database. Dữ liệu cuối cùng đến endpoint HTTP do bạn chỉ định — hoàn toàn dưới quyền kiểm soát của bạn.

---

### 4.3. Về Vận Hành & Scale

**Q: Backend cần chuẩn bị gì để nhận event?**

A: Một HTTP endpoint nhận POST request với JSON array, header `Authorization: Bearer <api_key>`. Cấu trúc event là flat JSON object với các field chuẩn (`event_name`, `timestamp`, `session_id`, `screen`, `properties`...). Có thể dùng bất kỳ stack nào: Node.js, Go, Python, hay managed service như AWS API Gateway.

---

**Q: Throughput tối đa SDK có thể xử lý?**

A: Queue tối đa 10,000 events. Batch size mặc định 50 events/request. Flush mỗi 5 giây. Về lý thuyết: ~600 requests/phút từ một device. Sampling rate có thể giảm volume nếu cần.

---

**Q: Làm sao debug khi event không lên server?**

A: Set `logLevel: .debug` khi khởi tạo. SDK sẽ log chi tiết mọi event enqueue, flush attempt, HTTP response. Trên Android có thể dùng `adb logcat | grep UniTrack`.

---

**Q: Có dashboard hay visualization sẵn không?**

A: SDK là transport layer — không kèm dashboard. Bạn có thể pipe event vào bất kỳ data warehouse hay BI tool nào (Amplitude, Mixpanel custom ingest, BigQuery, ClickHouse, Grafana...).

---

### 4.4. Về Phí & Licensing

**Q: Model pricing như thế nào?**

A: *(Tùy bên tích hợp định nghĩa — per-event, per-MAU, hay flat fee. SDK không tự charge.)*

---

**Q: Có SLA gì không?**

A: SDK chạy hoàn toàn on-device — uptime phụ thuộc vào infrastructure backend của bạn, không phụ thuộc vào uptime của UniTrack. Dữ liệu không bao giờ đi qua server của UniTrack.

---

## 5. Nội Dung Cho Slide Presentation

> Cấu trúc slide gợi ý — 10–12 slide, 20–30 phút trình bày

---

### Slide 1 — Cover

**Tiêu đề**: UniTrack SDK
**Sub**: Auto-capture analytics cho mọi mobile platform
**Visual gợi ý**: Hình điện thoại với các event tự động "bắn ra" — screen, tap, network, crash

---

### Slide 2 — Vấn Đề Hiện Tại

**Tiêu đề**: Tracking hiện tại... tốn công và không nhất quán

3 bullet points:
- Developer phải viết tay từng `logEvent()` → dễ bỏ sót, tốn thời gian
- 4 platform → 4 cách tích hợp khác nhau → data không đồng nhất
- Phải cài nhiều SDK khác nhau: crash SDK + analytics SDK + network SDK

**Visual gợi ý**: Code snippet dài với hàng chục logEvent() call manual

---

### Slide 3 — Giải Pháp: UniTrack

**Tiêu đề**: Một SDK. Mọi thứ tự động.

Lớn, bold:
> "Khởi tạo một lần. UniTrack theo dõi mọi thứ."

4 icon + label:
- Screen Views
- Taps & Clicks
- Network Requests
- Crashes & Errors

---

### Slide 4 — Kiến Trúc

**Tiêu đề**: Một C++ Core, Bốn Platform

Diagram (top-to-bottom):
```
iOS  |  Android  |  React Native  |  Flutter
              ↓ ↓ ↓ ↓
         C++ Shared Core
    [Queue] [Transport] [Session] [Crash]
              ↓
         Your Backend
```

Key message: **"Fix once, all platforms benefit"**

---

### Slide 5 — Auto-Capture In Action

**Tiêu đề**: Không cần code thủ công

Hai cột:
| Trước (Firebase/Snowplow) | Sau (UniTrack) |
|---|---|
| 50+ logEvent() calls | 3 dòng init |
| Thiếu event khi dev quên | Tự động 100% |
| Khác nhau giữa iOS/Android | Nhất quán hoàn toàn |

**Visual gợi ý**: Before/after code diff

---

### Slide 6 — Events Được Track Tự Động

**Tiêu đề**: Mọi hành vi. Không sót gì.

Grid 3x3 với icon:
- Screen View
- Tap / Click
- Network Request
- App Start (cold start time)
- App Foreground / Background
- Memory Warning
- Crash (native signal)
- JSON Parse Error
- Deeplink / Push Notification

---

### Slide 7 — So Sánh Với Firebase

**Tiêu đề**: UniTrack vs Firebase Analytics

Bảng so sánh 5 tiêu chí quan trọng nhất:
- Auto-capture ✓ vs ✗
- Crash tracking ✓ built-in vs cần Crashlytics riêng
- Network tracking ✓ vs ✗
- Data ownership: bạn vs Google
- Vendor lock-in: Không vs Có

---

### Slide 8 — So Sánh Với Snowplow

**Tiêu đề**: UniTrack vs Snowplow

Key differences:
- Setup: 5 phút vs vài ngày
- Auto-capture: Có vs Không
- Infrastructure: HTTP endpoint đơn giản vs Kafka + Enrich pipeline
- Target: Mobile dev team vs Data engineering team

---

### Slide 9 — Offline-First & Reliability

**Tiêu đề**: Không mất event. Dù mất mạng.

Flow diagram:
```
Event xảy ra → SQLite local → [Có mạng?] → HTTP batch → Server
                    ↑                             ↑
              [Không mạng]              [Retry tự động]
```

Numbers:
- 10,000 event queue capacity
- 7 ngày retention local
- < 1ms overhead per event

---

### Slide 10 — Privacy & Security

**Tiêu đề**: Privacy by Default

- Không thu thập PII mặc định
- Network call chỉ log host + path (không log body, query, auth header)
- Dữ liệu đến server của bạn — không qua UniTrack
- GDPR-ready: `reset()` API để xóa user data

---

### Slide 11 — Tích Hợp Đơn Giản

**Tiêu đề**: Từ 0 đến tracking trong 5 phút

Code snippet 4 platform (tabs):

**iOS (Swift)**
```swift
UniTrack.initialize(config: .init(apiKey: "YOUR_KEY"))
```

**Android (Kotlin)**
```kotlin
UniTrack.initialize(this, UniTrack.Config(apiKey = "YOUR_KEY"))
```

**React Native**
```typescript
UniTrack.initialize({ apiKey: 'YOUR_KEY' })
```

**Flutter**
```dart
await UniTrack.initialize(UniTrackConfig(apiKey: 'YOUR_KEY'));
```

---

### Slide 12 — Call to Action

**Tiêu đề**: Bắt Đầu Ngay Hôm Nay

3 bước:
1. Thêm dependency vào project
2. Gọi `initialize()` với API key
3. Xem data flow về server của bạn

Contact / Repo link / Documentation link

---

## 6. Ghi Chú Cho Claude Design

Khi tạo template slide, cần:

**Tone & Visual Direction:**
- Professional, tech-forward, clean
- Dark theme hoặc gradient xanh đậm/tím — gợi cảm giác infrastructure, reliability
- Font: Sans-serif modern (Inter, DM Sans, hoặc tương tự)
- Icon style: Flat, monochrome hoặc duotone
- Diagram style: Minimalist flow chart với rounded corners

**Màu sắc gợi ý:**
- Primary: #1A1A2E (dark navy) hoặc #0F172A
- Accent: #6366F1 (indigo) hoặc #38BDF8 (sky blue)
- Success/check: #22C55E
- Text: #F8FAFC

**Layout ưu tiên:**
- Slide rộng (16:9)
- Nhiều whitespace
- Data/số liệu được highlight lớn (big number style)
- Bảng so sánh dùng checkmark ✓ và ✗ rõ ràng

**Slide đặc biệt cần thiết kế kỹ:**
- Slide 4 (Architecture diagram): cần diagram đẹp, rõ flow
- Slide 7 & 8 (Comparison table): cần bảng clean, dễ đọc
- Slide 11 (Code snippet): cần code block đẹp với syntax highlight
