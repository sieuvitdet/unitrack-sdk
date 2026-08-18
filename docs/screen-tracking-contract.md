# Screen tracking contract (Snowplow hybrid mode)

Trạng thái: **iOS xong, Android CHƯA có** (xem phần "Việc còn lại").
Cập nhật: 2026-08-19.

## Nguyên tắc

SDK này lấy **Snowplow làm chuẩn**. Screen event dùng **builtin schema của
Snowplow**, không dùng custom vendor. Thứ duy nhất thêm vào là `event_action`
/ `action_name` — và nó nằm trong **context entity `core_action`**, không nằm
trong event body.

Lý do không nhét vào event body: `ScreenView.payload` (`ScreenView.swift:76`)
là closed set, schema `com.snowplowanalytics.mobile/screen_view/1-0-0` khóa
field. Thêm field lạ → bad row ở enricher. Snowplow thiết kế **entity** đúng
cho mục đích này.

## Bảng ánh xạ (spec đội Data ↔ implementation)

| event_action | Event trên wire | Vendor | Nguồn |
|---|---|---|---|
| `screen_viewed` | `screen_view` | `com.snowplowanalytics.mobile` | builtin, SDK gọi `ScreenView()` trong `setScreen()` |
| `screen_exited` | `screen_end` | `com.snowplowanalytics.mobile` | builtin, **Snowplow tự fire** |
| `screen_load_completed` | `screen_view` | `vn.fpt.ftel.snowplow` | **custom — giữ nguyên** |

`screen_load_completed` **phải** giữ custom: Snowplow không có khái niệm
tương đương, và `load_time_ms` chỉ UniTrack đo được qua swizzler.

## Field lấy ở đâu

| Field spec | Vị trí thật |
|---|---|
| `session_id` | `core_action.session_id` |
| `screen_name` (screen_viewed) | event data `name` |
| `previous_screen_name` | event data `previousName` |
| `screen_name` (screen_exited) | entity `screen.name` **hoặc** `core_action.screen` |
| `foreground_sec` | entity `screen_summary.foreground_sec` |

`screen_end` có payload **rỗng hoàn toàn** — mọi thứ nằm trong entity. Đây là
thiết kế của Snowplow, không phải thiếu sót.

## Config bắt buộc

`trackingConfig.json`:
```json
"hybrid_screen_view": true,
"options": {
  "screenEngagementAutotracking": true,   // BẮT BUỘC — không bật thì screen_end + screen_summary KHÔNG fire
  "lifecycleAutotracking": false          // để false: tránh app_foreground/app_background rác
}
```

Về `lifecycleAutotracking: false` — đánh đổi đã cân nhắc: `foreground_sec`
vẫn có (`ScreenSummaryState.updateForScreenEnd()` tự cộng), chỉ mất khả năng
tách riêng thời gian background giữa chừng. Nếu user background > 30 phút thì
session rotate rồi nên không quan tâm; dưới 30 phút thì sai lệch nhỏ, chấp nhận.

## Bốn cái bẫy đã dính (đừng lặp lại)

### 1. `action_name` bị portal config đè
`resolveEventName(kind:defaultName:)` đọc `eventNames[kind]` — map đó để
resolve **SCHEMA name**, không phải action name. FPT Life đặt
`event_names.screen_view = "screen_view"` → đè mất default `"screen_viewed"`,
production ship `action_name = "screen_view"` suốt nhiều tuần.

→ Action name giờ là **constant** `SnowplowProvider.actionScreenViewed` /
`.actionScreenExited`. **Không** cho portal override.

### 2. `screen_end` không tự có `core_action`
Snowplow fire `screen_end` trong `ScreenSummaryStateMachine`, SDK không gọi
nên không chèn entity như `setScreen()` làm với `ScreenView`.

→ Dùng `GlobalContext(generator:filter:)` — hook chuẩn của Snowplow, match
theo schema. Xem `makeScreenEndContext()`. Chỉ đăng ký khi `hybridScreenView`.

### 3. `event.entities` rỗng trong GlobalContext generator
Snowplow gắn entity `screen` **sau khi** generator chạy, nên đọc
`event.entities` trong generator trả rỗng. Đo thật: session `7785b4db`,
76/76 event `screen_end` thiếu `core_action.screen`.

→ Lấy từ `UniTrack.previousScreenName()` (state UniTrack giữ) thay vì đọc entity.

### 4. Portal lấy nhầm `session_id` (lỗi portal, không phải SDK)
`snowplow.js` cũ:
```js
if (/client_session/i.test(...)) clientSessionId = clientSessionId || c.data.sessionId;
if (/core_action/i.test(...))    clientSessionId = clientSessionId || c.data.session_id;  // KHÔNG BAO GIỜ CHẠY
```
`||` nên entity duyệt trước thắng. Với `screen_end` builtin, `client_session`
đứng trước `core_action` → portal lấy **sessionId của Snowplow** thay vì của
UniTrack. Kết quả: 1 phiên thật bị tách 2 session_id (`7785b4db` → sinh thêm
`8ed47393` cho 76 event).

→ Đã sửa: biến riêng `coreActionSessionId`, ưu tiên
`sp.sid || coreActionSessionId || clientSessionId`.

**Snowplow `client_session.sessionId` ≠ UniTrack `session_id`.** Hai khái niệm
độc lập. Luôn join theo `core_action.session_id`.

## Cách verify

Trên VPS (`root@103.188.83.49`):
```bash
./check_session.sh <session_id_prefix>   # hoặc bỏ trống = session mới nhất
```
In ra: builtin vs custom, `action_name` + session_id/screen CÓ/THIẾU,
`screen_summary.foreground_sec`, timeline, và cảnh báo tự động.

Kết quả đúng:
```
BUILTIN screen_view  →  screen_viewed
BUILTIN screen_end   →  screen_exited
CUSTOM  screen_view  →  screen_load_completed
screen_summary: fg_sec có số
(không có dòng [!])
```

## Việc còn lại

- **Android chưa có hybrid mode.** `SnowplowProvider.kt` không có
  `hybridScreenView`, không có `GlobalContext`. Android hiện vẫn chạy custom
  vendor hoàn toàn. Port sang Kotlin trước khi tắt custom cho Android.
- **Phantom screen ~51%** (`dwell_ms ≤ 10ms`): container VC
  (`AppTabBarPager*`, `FSSHomeTabBar*`, `MainHome*`, `ContextParent*`) đạt
  95-100% phantom, screen nghiệp vụ thật 0-5%. Chưa xử lý. Cần đo lại sau khi
  chuyển hẳn sang builtin — Snowplow quản screen state riêng nên tỉ lệ có thể
  khác.
