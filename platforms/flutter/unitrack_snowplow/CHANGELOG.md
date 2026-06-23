# Changelog

## 1.1.0 — 2026-06-23

### Added

- **`SnowplowProvider.fromPortal(cfg)` factory** — đọc Portal config 1 cú gọi,
  tự wire endpoint / appId / iglu_vendor / event_names / entities / options /
  userContext. Returns `null` khi Portal disable hoặc thiếu endpoint/appId.

  ```dart
  final sp = SnowplowProvider.fromPortal(
    remoteCfg,
    namespace: 'MobiX',
    fallbackIgluVendor: 'vn.fpt.ftel.snowplow',
  );
  if (sp != null) UniTrack.instance.addProvider(sp);
  ```

- **`SnowplowOptions` parity field**: `screenViewAutotracking`,
  `deepLinkContext`, `exceptionAutotracking`, `installAutotracking`. Accept
  trong API cho parity iOS+Android. ⚠️ **Không thread xuống native** ở
  Flutter (snowplow_tracker plugin chưa support) — chấp nhận giá trị nhưng
  no-op. Sẽ wire khi plugin upgrade.

### Fixed

- **Race condition** `setUser()` không refresh `_appCtxCache` — user login →
  identify → event ngay sau có thể dùng app_ctx của user trước (nếu app_ctx
  chứa user-derived field như `account_id`).
- **Race condition** `applyOptions()` rebuild tracker nhưng không refresh
  cache — flavor switch có thể stamp stale `applicationContext` lên event đầu.

### Requires

- `unitrack ^1.2.0` (cần `UniTrackConfig.fromMap()` + `snowplowEntityURIs`).

## 1.0.1 — 2026-06-22

Parity fix với iOS + Android Snowplow providers — Flutter trước đây không build
`application_context` entity và không stamp `session_id` vào `core_action`, dù
Portal config có entities map đầy đủ. Hậu quả: payload Snowplow chỉ có
`event.data` + `user_context`, thiếu `application_context` + thiếu join key
session.

### Fix

- `_buildContexts` giờ build `application_context` entity từ cache
  `UniTrack.applicationContext()` (bundle / version / device_name / network /
  platform — auto-collect ở core, app không phải feed).
- `core_action` entity bổ sung `action_name`, `start_time`, `session_id` —
  khớp shape Android `SnowplowProvider.kt:240-256`.
- Cache `_appCtxCache` + `_sessionIdCache` refresh ở `init()` + fire-and-forget
  trên mỗi `track()` để `_buildContexts` giữ sync (đối xứng iOS/Android dùng
  native sync getter).

### Yêu cầu

- `unitrack ^1.1.1` (cần `currentSessionId()` + `applicationContext()` APIs).

## 1.0.0 — 2026-06-09

Initial public release.

- `SnowplowProvider` implements `AnalyticsProvider` so any UniTrack event
  fans out to the configured Snowplow collector.
- Auto-attached entities: `user_context`, `core_action`,
  `application_context` — same shape the native iOS / Android providers send.
- `kindForRawEvent` routing: `screen_viewed`, `screen_exited`,
  `screen_load_completed` → `screen_view` kind with stamped `event_action`.
- Built-in convention helpers: `trackingClickEvent`, `trackingResultEvent`,
  `trackingScreenView`, `trackingCrash`, `trackingAPI`, `trackingSession`.
- Per-event Iglu schema resolution with `igluVendor`, `defaultVersion`,
  `eventNames` overrides, and per-name `entities` map.
- Optional portal mirror for side-by-side log inspection.
