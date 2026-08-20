# Screen tracking contract (Snowplow hybrid mode)

Cập nhật: 2026-08-20.

| Platform | Code | Verify runtime |
|---|---|---|
| iOS | ✅ xong | ✅ đã đo trên portal |
| Android | ✅ xong (parity 1:1 với iOS) | ✅ đã đo 2026-08-20 (JitPack 0.3.60, app 2.16.1, Xiaomi 23106RN0DA) |
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

## Sáu cái bẫy đã dính (đừng lặp lại)

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

### 5. `core_action.screen` trên `screen_end` là màn VÀO, không phải màn RỜI

Bẫy #3 chốt "lấy từ `UniTrack.previousScreenName()`" — đúng hướng nhưng
**sai thời điểm**. `setScreen()` đã gán `lastScreen = name` (màn mới) TRƯỚC khi
fan-out xuống provider (`UniTrack.swift:857` → `:867`, `UniTrack.kt:899` →
`:907`). Provider fire builtin `ScreenView`, Snowplow fire `screen_end` ngay
trong `track()` đó, generator đọc `previousScreenName()` → nhận **màn vừa vào**.

Đo thật (2026-08-20, so `core_action.screen` với entity `screen` của Snowplow —
entity này Snowplow tự gắn nên là nguồn đúng):

| Session | Platform | MATCH | MISMATCH |
|---|---|---|---|
| `482b48d9` + `f543d101` + `1154bc0d` | iOS | 1 | **52** |
| `922e5be6` + `722f6915` | Android | 18 | **39** |

Ví dụ rõ nhất (iOS `482b48d9`, dòng đầu): Snowplow nói màn kết thúc là
`ISCFlashScreenSyncDataViewController` với `foreground_sec = 227.21` (đúng —
splash user ngồi 3 phút), `core_action.screen` ghi `CameraHomeViewController`
(màn vừa mở). Đội Data join theo `core_action` → **mọi `screen_exited` gán sai
màn**, và `foreground_sec` bị quy cho màn không liên quan.

→ Fix: `setScreen()` stash màn đang rời vào `exitingScreen` NGAY TRƯỚC
`tracker.track(sv)`; generator đọc biến đó, chỉ fallback về
`previousScreenName()` khi không có setScreen đi trước (app background —
lúc đó `lastScreen` CHÍNH LÀ màn đang rời nên fallback đúng).

Không đọc `event.entities` (bẫy #3 vẫn đúng) và không dùng
`com.snowplowanalytics.core.screenviews.*` — internal API, không stable.

### 6. Force-quit rồi mở lại sau 1 giây vẫn đẻ session mới

Hai lỗi độc lập, phải sửa cả hai:

**(a) iOS không bao giờ báo core là đã background sạch.** Android gọi
`ut_log_background()` trong lifecycle observer, iOS thì không — nên
`clean_shutdown` không bao giờ được persist, mọi lần mở app đều trông như
bị kill. Fix ở `AppLifecycleObserver.swift`: **thay** `track("app_background")`
bằng `UniTrack._logBackgroundToCore()` (core tự bắn event bên trong
`log_background()`, gọi cả hai là double-fire — Android không gọi `track`).

Verify bằng cách kéo `session.json` khỏi máy thật:
```bash
xcrun devicectl device info files --device <UDID> \
  --domain-type appDataContainer --domain-identifier <bundle-id> \
  --source Library/Application\ Support/unitrack/session.json --destination /tmp/
```
→ đọc được `"clean_shutdown":1`. Xong bước (a).

**(b) `killed_recovered` không nhìn độ dài gap.** Đây mới là gốc. `load_from()`
chỉ hỏi "`clean_shutdown` có false không" rồi rotate ngay, gap 1 giây hay 29
phút xử lý y hệt. Mà `clean_shutdown = false` **không phải bằng chứng bị kill**:
iOS có thể kill app đang suspend trước khi state write kịp xuống đĩa (SDK không
giữ `beginBackgroundTask` assertion). User force-quit rồi mở lại ngay → session
mới, dù cùng một phiên sử dụng.

→ Fix: `KILL_GRACE_MS = 10s` trong `session_manager.cpp`. Relaunch không sạch
mà gap ≤ 10s thì **resume** session cũ, quá 10s mới `killed_recovered`. Timeout
30 phút vẫn rotate như cũ.

Replay đúng chuỗi đo được trên máy thật (gap 2250 / 843 / 1286 ms):
**4 session → 1**. Test `test_session_kill_grace()` trong `tests/core_tests.cpp`.

**(c) `last_activity_ms` không bao giờ xuống đĩa — đây mới là gốc thật.**
Đo lại 2026-08-20 22:00 với bản có `KILL_GRACE_MS`: vẫn **9 session trong 17
giây**, `session_index` 15→23, gap nhỏ nhất **0.18s**. Kéo `session.json` khỏi
iPhone 15 Pro (`Documents/session.json`, không phải `Library/…`):

```json
{"session_index":26,"started_at_ms":1787241093989,
 "last_activity_ms":1787241093989,"clean_shutdown":1}
```

`started_at_ms == last_activity_ms` — đồng hồ **chưa bao giờ nhúc nhích trên
đĩa**. `stamp_for_event()` có `last_activity_ms_ = now` nhưng chỉ
`save_locked()` cho event ĐẦU TIÊN của session; mọi event sau chỉ đổi RAM.
Nên `load_from()` lần sau đo gap từ **thời điểm sai** — trải dài cả session
trước — và `KILL_GRACE_MS` 10s không bao giờ khớp.

Cũng bác bỏ luôn giả thuyết scene-lifecycle: `clean_shutdown:1` chứng minh
`_logBackgroundToCore()` CÓ chạy, `didEnterBackgroundNotification` vẫn fire
bình thường trên app scene-based.

→ Fix (0.3.64): persist theo throttle ~10s (`ACTIVITY_SAVE_INTERVAL_MS`) ở cả
`stamp_for_event()` lẫn `resolve()` — `resolve()` có thể là thứ cuối cùng chạy
trước force-quit mà không có event nào theo sau.

Test `test_session_activity_persisted`: fail trên code cũ (126/7), pass sau fix
(127/6). 6 fail còn lại là pre-existing.

**Bài học:** 0.3.63 kết luận `KILL_GRACE_MS` là root cause dựa trên test replay
và đã ghi rõ "chưa verify runtime". Dữ liệu thật cho thấy nó đúng nhưng **không
đủ** — fix nằm ở tầng persist chứ không phải tầng quyết định. Đừng đóng bẫy khi
mới có test xanh.

**Phát hiện kèm:** FPT Life dùng scene-based lifecycle
(`UIApplicationSceneManifest`), nên `applicationDidEnterBackground` không bao
giờ fire → không có `session_ended`. Việc của app, không phải SDK.

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

## Kết quả đo thật (Android, 2026-08-20)

Session `922e5be6` + `722f6915`, Xiaomi 23106RN0DA / Android 15, app 2.16.1
(staging `vn.fpt.fptlife.staging`), JitPack `0.3.60`:

| Kiểm tra | Kết quả |
|---|---|
| `action_name` | `screen_viewed` / `screen_exited` / `screen_load_completed` — đúng spec |
| `session_id` trong `core_action` | CÓ 100% (129/129) |
| Custom `screen_end` trùng lặp | 0 — hybrid skip chạy đúng |
| Portal tách session | hết — `portal_sid` khớp `core_action.session_id` 100% |
| `screen_summary.foreground_sec` | có số |
| `core_action.screen` đúng màn | ❌ 18/57 — bẫy #5, đã fix, **chưa đo lại** |

## Kết quả đo lại sau fix (iOS, 2026-08-20 15:26, SDK 0.3.62)

Session `5ddfd1f9` + 3 session cùng đợt, iPhone 15 Pro, app 2.17.0:

| Kiểm tra | Trước fix | Sau fix |
|---|---|---|
| `action_name` đúng spec | ✅ | ✅ |
| `session_id` + `screen` trong `core_action` | CÓ 100% | CÓ 100% |
| Builtin `screen_view` : `screen_end` | — | 30:30 |
| **Bẫy #5** — màn hình thật (`fg > 0`) | 1/53 đúng | **32/34 đúng (94%)** |
| **Bẫy #5** — phantom (`fg = 0`) | — | 11/27 đúng |
| **Bẫy #6** — rotate sớm | 7 lần | vẫn còn 3 lần ⚠️ |

Bẫy #5 coi như **xong cho màn hình thật**. 16/18 row còn sai đều là phantom
container (`foreground_sec = 0`) — 4 màn fire trong ~10ms, `exitingScreen` bị
ghi đè trước khi Snowplow kịp drain. Cùng gốc với vấn đề phantom sẵn có, đội
Data lọc `foreground_sec > 0` là hết.

## Việc còn lại

- **Bẫy #6 (rotate sớm)** — gốc thật là `last_activity_ms` không persist, fix
  vào `0.3.64`. **Chưa verify runtime** (0.3.63 cũng từng xanh test rồi fail
  trên máy thật — xem bẫy #6c). Đo lại bằng `check_session.sh` section 7, kỳ
  vọng 0 dòng `[!] ROTATE SOM`.
- **Phantom screen ~44%** — xem mục dưới, không đổi.
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
