# Screen tracking contract (Snowplow hybrid mode)

Cập nhật: 2026-08-19.

| Platform | Code | Verify runtime |
|---|---|---|
| iOS | ✅ xong | ✅ đã đo trên portal |
| Android | ✅ xong (parity 1:1 với iOS) | ⏳ chưa test — cần tag JitPack mới |
| Web | ❌ chưa có hybrid | — |

Web hiện dùng custom vendor hoàn toàn: đã có `event_action` + `session_id`
(`platforms/web/src/index.ts:151`, `providers/snowplow.ts:52`) và
`screenStartEvent: 'screen_viewed'` (`index.ts:231`) — tức **tên event đã đúng
spec**. Thiếu: builtin ScreenView + GlobalContext cho `screen_end`. Xem phần
"Port sang platform mới" bên dưới trước khi làm.

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

## Kết quả đo thật (iOS, 2026-08-19)

Session `f543d101` + `a9570210`, iPhone 15 Pro, app 2.17.0:

| Kiểm tra | Kết quả |
|---|---|
| `action_name` | `screen_viewed` / `screen_exited` / `screen_load_completed` — đúng spec |
| `session_id` + `screen` trong `core_action` | CÓ 100% |
| Builtin `screen_view` : `screen_end` | 20:20 và 40:39 (lệch 1 = màn cuối chưa thoát, đúng) |
| Custom `screen_exited` trùng lặp | 0 (trước fix: 76 bản sao) |
| Portal tách session | hết — `portal_sid` khớp `core_action.session_id` 100% |
| Rotate sau 30' idle | đúng — gap 48 phút giữa 2 session → id mới |
| App treo background | không sinh event rác (đúng, vì `lifecycleAutotracking: false`) |

## Port sang platform mới (vd Web)

Làm theo đúng thứ tự này, mỗi bước đều có bẫy đã dính ở phần trên:

1. **Cờ `hybridScreenView`** đọc từ config `snowplow.hybrid_screen_view`.
   App phải truyền cờ xuống provider — Android từng thiếu bước này
   (`FSDKTrackingConfig.kt`), cờ có trong JSON mà provider không nhận.
2. **`setScreen()` fire builtin ScreenView**, stamp `previousName` từ state
   của UniTrack, KHÔNG để Snowplow tự suy (nó không thấy `screen_exited`
   lúc app background → resume sẽ ghi sai màn trước).
3. **`action_name` = hằng số**, không đi qua `eventNames[kind]`. Xem bẫy #1.
4. **GlobalContext cho `screen_end`** — xem bẫy #2 và #3.
5. **`track()` skip** custom `screen_viewed`/`screen_exited` khi hybrid bật.
   GIỮ `screen_load_completed`.
6. **Config**: `screenEngagementAutotracking: true` (bắt buộc),
   `lifecycleAutotracking: false`.
7. **Verify bằng `check_session.sh`**, không tin build-pass là xong — 3 trong
   4 cái bẫy ở trên chỉ lộ ra khi đo dữ liệu thật.

Lưu ý cho Web: `screen_end` là khái niệm mobile. Snowplow JS tracker có
`enableActivityTracking` / page ping thay vì `screen_summary` — kiểm tra API
thật của tracker web trước khi bê nguyên thiết kế mobile sang.

## Việc còn lại

- **Android chưa test runtime.** Code xong + compile sạch, nhưng app đang pin
  JitPack `0.3.57-headless1` → cần tag mới thì JitPack mới build artifact.
- **Phantom screen ~44%** (`screen_summary.foreground_sec = 0`): container VC
  lồng nhau khi chuyển tab, user không hề nhìn thấy — đo được 4 màn hình trong
  16ms trên một lần chuyển tab.

  Đã kiểm chứng: **chuyển sang builtin KHÔNG khử được phantom** (51% → 44%,
  không phải do fix mà do khác cách đo). Lý do: Snowplow tạo screen state dựa
  trên `setScreen()` mà swizzler gọi — swizzler vẫn bắn cho container VC thì
  Snowplow vẫn tạo state.

  **Không làm blocklist theo tên VC** — hardcode kiến trúc của một app, không
  thuộc về SDK dùng chung (quyết định của product owner, 2026-08-19).

  Hai hướng còn mở:
  - Đội Data lọc `foreground_sec > 0` ở tầng query — 0 công sức
  - SDK thêm `min_screen_dwell_ms` configurable, mặc định 0 = tắt — mỗi dự án
    tự chỉnh, không hardcode gì
