# Changelog

## 1.1.4 — 2026-06-23

### Added

`UniTrackConfig.fromMap()` factory — build config từ `remoteCfg.sdkConfig` Map
(Portal sdk_config block). App không phải lặp lại default hard-code khi cấu
hình autoCapture/trackScreens/trackTaps/trackNetwork ở Portal.

```dart
final remoteCfg = await UniTrackRemoteConfig.fetch(...);
await UniTrack.instance.initialize(
  apiKey,
  config: UniTrackConfig.fromMap(remoteCfg.sdkConfig),
);
```

Chấp nhận cả `snake_case` (Portal default) lẫn `camelCase` cho mỗi field. Field
thiếu/sai type tự fallback default constructor.

## 1.1.3 — 2026-06-23

### Fix

`UniTrackRemoteConfig.snowplowEntities` luôn trả map rỗng dù Portal đã set
entities. Lý do: getter yêu cầu `value is Map` nhưng Portal serialize entities
thành `Map<String, String>` (entity short-name → iglu URI). Hậu quả:
SnowplowProvider không build entity nào → log `contexts: []`.

- Thêm getter mới `snowplowEntityURIs: Map<String, String>` đúng shape Portal.
  App pass thẳng vào `SnowplowProvider(entities:)`.
- `snowplowEntities` cũ marked `@Deprecated` — giữ để không vỡ consumer cũ
  (camera demo) — nhưng tất cả call site nên migrate sang `snowplowEntityURIs`.

## 1.1.2 — 2026-06-22

### Breaking (Dart-only, minor — chỉ ảnh hưởng code gọi `defaultIgluSchema`)

`UniTrackRemoteConfig.defaultIgluSchema` không còn hard-code FTel vendor.

**Trước:**
```dart
static String defaultIgluSchema(String eventName, {String version = '1-0-0'}) {
  return 'iglu:vn.fpt.ftel.snowplow/$eventName/jsonschema/$version';
}
```

**Sau** (instance method, vendor đọc từ portal hoặc tham số):
```dart
String defaultIgluSchema(String eventName,
    {String version = '1-0-0', String? vendor}) { ... }
```

Vendor lookup precedence:
1. tham số `vendor:` (explicit)
2. `snowplow.iglu_vendor` từ Portal
3. throw ArgumentError (không có fallback FTel)

### Lý do

SDK không nên biết tenant. Vendor là khái niệm của app/portal, không phải SDK.
Apps đa tenant lấy vendor từ Portal; single-tenant pass inline.

### Migration cho app FPT (vd MobiX, FPT Life)

Đến khi Portal expose `snowplow.iglu_vendor`, app pass fallback:
```dart
final igluVendor = remoteCfg.snowplowIgluVendor.isNotEmpty
    ? remoteCfg.snowplowIgluVendor
    : 'vn.fpt.ftel.snowplow';
remoteCfg.defaultIgluSchema(eventName, vendor: igluVendor);
```

## 1.1.1 — 2026-06-22

Hotfix release. 1.1.0 archive thiếu native source vì `flutter pub publish`
lọc file qua `git ls-files` — folder `ios/Native/` + Android SDK source untracked
nên không lên pub.dev, gây lỗi "Cannot find 'UniTrack' in scope" ở Xcode.

### Fix

- `ios/Native/` (Swift SDK + C++ core) giờ tracked trong git để `pub publish`
  thấy.
- Android SDK source vendored vào `android/unitrack_sdk/src/` — pod tự build
  Kotlin + JNI/C++ thay vì trỏ ra `../../android/unitrack` (path đó không tồn
  tại trong pub-cache consumer app).
- Thêm `platforms/flutter/sync_native.sh` — chạy script này trước mỗi
  `pub publish` để đồng bộ Native/ + unitrack_sdk/ với monorepo source.

## 1.1.0 — 2026-06-22

Catch-up release đưa Flutter SDK lên ngang iOS 0.3.36 + Android 0.3.11.

### Mới

- **Built-in `HttpProvider`** — gửi event lên Kibana / ELK / backend FPT nội
  bộ qua `addHttpProvider()` API. Portal Config tab là source of truth, app
  không phải code tay. 4 PayloadFormat (JSON_SINGLE / JSON_LINES / JSON_ARRAY
  / ELASTIC_BULK). Retry exponential backoff 1s → 5min, max 10 lần, TTL 7 ngày.
- **Per-provider ack queue** — Mô hình B: event chỉ xoá khỏi queue khi tất cả
  provider ack SUCCESS. Provider nào trả RETRY thì giữ lại, exponential backoff
  per id. Snowplow / Firebase / Custom HTTP đều được retry chuẩn ngành.
- **`FirebaseAdapter` qua reflection** — `attachFirebaseAdapter()` stamp
  `session_id` vào mọi event Firebase Analytics qua `NSClassFromString` /
  `Class.forName`. UniTrack 0 import Firebase: app chưa cài → no-op, cài sau
  → bridge tự kích hoạt.
- **W3C Trace Context auto-inject** — header `traceparent` chèn vào HTTP
  request đi tới host trong allowlist Portal (fail-closed).
- **Kill detection** — `clean_shutdown` flag persist vào session.json. Cold
  start kế tiếp fire `session_ended` với reason `killed_recovered` ngay, không
  đợi 30 phút timeout.

### Bỏ

- `tracking_id` / `currentTrackingId` API — `session_id` là khóa join duy nhất
  giữa Portal / Snowplow / Firebase / custom backend. Apps gọi `currentTrackingId`
  phải đổi sang `currentSessionId`.

### Fix

- `UniTrackConfigStream.ingest()` String index out-of-bounds crash khi SSE
  chunk có unicode multi-byte. Đổi sang `components(separatedBy:)`.

### Native sync

10 file Swift + 3 file C++ trong `ios/Native/` đã sync với iOS 0.3.36 source.

## 1.0.0 — 2026-06-09

Initial public release.

### Features

- Auto-capture: screen, tap, network, crash, OOM, JSON-parse error.
- Persistent SQLite offline queue with exponential backoff retries.
- Session journey tracking — `session_id` + `session_index` persist across
  cold starts via `session.json`.
- W3C trace-context (`traceparent` header) opt-in injection with host allowlist.
- Provider fan-out: bring your own analytics destination by implementing
  `AnalyticsProvider`. Two first-party providers shipped separately:
  - [`unitrack_snowplow`](https://pub.dev/packages/unitrack_snowplow)
  - [`unitrack_firebase`](https://pub.dev/packages/unitrack_firebase)
- Public APIs include:
  - `initialize / track / identify / reset / setScreen / flush / setEnabled`
  - `currentSessionId / sessionIndex / previousSessionId / rotateSession`
  - `pendingEventCounts / onFlushCompleted` (offline-test introspection)
  - `applicationContext / getRemoteValue<T>`
  - `trackNotification / captureNotification / trackDeeplink / trackUrlLaunch`
  - `UniTrackNavigatorObserver` for route auto-capture
  - `setTracing` + `UniTrackTraceContext` for W3C distributed tracing
