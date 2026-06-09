# Changelog

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
