# Changelog

## 1.1.0 — 2026-06-23

### FirebaseAdapter — stamp session_id qua `setDefaultEventParameters`

Parity với iOS Native + Android Native + Flutter SDK 1.2.1.

Trước đây UniTrack chỉ stamp `session_id` vào params khi event đi qua
`UniTrack.track()`. App gọi `FirebaseAnalytics.logEvent()` thẳng (bypass
UniTrack, vd Firebase Performance auto-events) KHÔNG có `session_id` ở params.

Fix: FirebaseAdapter giờ call `setDefaultEventParameters` ở 3 hook:
- `initialize()` — khi attach
- `track()` — khi session rotate
- `setUser()` — identity đổi

Firebase tự merge default params vào MỌI event sau đó.

### Native bumps

- iOS: vendored copy sync từ `platforms/ios` (FirebaseAdapter.swift).
- Android: JitPack dep bump `com.github.sieuvitdet:unitrack-sdk:0.3.3` → `0.3.37`.

### Requires app side

- Firebase iOS SDK 8.4+ (older SDK no-op an toàn).
- Firebase Android SDK 21.0.0+ (older SDK no-op).

## 1.0.0 — 2026-06-09

Initial public release.

### Features

- Auto-capture: screen, tap, network, crash, OOM, JSON-parse error.
- Persistent SQLite offline queue with exponential backoff retries.
- Session journey tracking — `session_id` + `session_index` persist across
  cold starts via `session.json`.
- W3C trace-context (`traceparent` header) opt-in injection with host allowlist.
- Provider fan-out: bring your own analytics destination by implementing
  `AnalyticsProvider`. Two first-party providers ship separately:
  - [`@unitrack/snowplow`](https://www.npmjs.com/package/@unitrack/snowplow)
  - [`@unitrack/firebase`](https://www.npmjs.com/package/@unitrack/firebase)
- Public APIs include:
  - `initialize / track / identify / reset / setScreen / flush / setEnabled`
  - `currentSessionId / sessionIndex / previousSessionId / rotateSession`
  - `pendingEventCounts / onFlushCompleted` (offline-test introspection)
  - `applicationContext / getRemoteValue<T>`
  - `trackNotification / trackDeeplink / trackThirdPartyOpen / trackWebViewOpen`
  - `setTracing` + `newTrace` for W3C distributed tracing
