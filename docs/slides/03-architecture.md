---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 03/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Architecture: 1 core C++, 4 platform binding

```
┌──────────────────────────────────────────────────────────┐
│                    Portal (Node.js + SQLite)             │
│  remote config · session IDE · heatmap · agent · forward │
└─────────────────────────────▲────────────────────────────┘
                              │ HTTPS batch
┌─────────────────────────────┴────────────────────────────┐
│  Native binding (Swift / Kotlin / Dart / TS)             │
│  ── Auto-capture (swizzle / wrap / observer / HOC)       │
│  ── Convention helpers (trackingClickEvent, …)           │
│  ── Provider fan-out (Snowplow, Firebase, custom)        │
└─────────────────────────────▲────────────────────────────┘
                              │ C ABI
┌─────────────────────────────┴────────────────────────────┐
│  C++ Core (core/src/)                                    │
│  ── Offline queue (SQLite, retry, batch)                 │
│  ── Session manager (timeout, journey)                   │
│  ── Crash signal handler (SIGSEGV → crash-pending.json)  │
│  ── HTTP transport (libcurl)                             │
│  ── W3C Trace Context (trace_id, span_id)                │
└──────────────────────────────────────────────────────────┘
```

---

## Tại sao C++ core?

| Lợi ích | Chi tiết |
|---|---|
| **DRY** | Offline queue + session logic + crash handler viết 1 lần |
| **Performance** | Background thread + SQLite trực tiếp, không qua JNI/RN bridge |
| **Crash trap** | SIGSEGV/SIGTRAP signal handler cần native code, JS/Dart không bắt được |
| **Battery** | Batch transport ở C++ tiết kiệm wake-up vs JS-side polling |

So với FLifeTracker (Swift only):
- Crash handler có sẵn ở core → app crash, lần mở sau tự fire `event_crash`
- Queue persistent qua SQLite → mất mạng vẫn không mất event

---

## Convention layer thay vì hardcode schema

**FLifeTracker** approach:
```swift
private enum SnowplowSchema {
  static let buttonClick = "iglu:com.snowplowanalytics.snowplow/button_click/jsonschema/1-0-0"
  static let networkError = "iglu:com.snowplowanalytics.snowplow/network_error_event_custom/jsonschema/1-0-0"
  // ... thêm 28 schema nữa
}
```

**UniTrack** approach (portal remote config):
```json
{
  "snowplow": {
    "iglu_vendor": "vn.fpt.ftel.snowplow",
    "default_version": "1-0-0",
    "event_names": {
      "click": "event_click",       ← đổi ở đây
      "result": "event_result",     ← thay vì rebuild
      "screen_view": "screen_view",
      "crash": "event_crash",
      "api": "event_api",
      "session": "event_session"
    }
  }
}
```

App code chỉ gọi `trackingClickEvent(elementKey: "btn_login")`, SDK build URI tự động.

---

## Repo layout

```
unitrack-sdk/
├── core/                          # C++ shared
│   ├── src/                       # tracker.cpp, queue, session, crash
│   └── include/unitrack/unitrack.h # C ABI
├── platforms/
│   ├── ios/                       # Swift binding + Snowplow + Firebase
│   ├── android/                   # Kotlin binding + 2 provider
│   ├── flutter/                   # Dart MethodChannel + provider
│   └── react-native/              # TS binding
├── portal/                        # Node.js admin + ingest
└── docs/slides/                   # Tài liệu này
```

**31MB code**, không tính build artifacts. Lean.

→ Slide tiếp: [04 — Auto-capture](04-what-we-auto-capture.md)
