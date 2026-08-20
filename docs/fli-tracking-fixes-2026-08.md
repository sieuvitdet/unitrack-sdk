# FPT Life tracking — nhật ký sửa lỗi (08/2026)

Cập nhật: 2026-08-20. Ghi lại **nguyên nhân gốc** của từng lỗi, cách sửa, và
trạng thái verify. Cuối file có **prompt mẫu** cho session CLI sau.

---

## Bảng tóm tắt

| # | Lỗi | Nguyên nhân gốc | Trạng thái |
|---|---|---|---|
| 1 | `event_action = "screen_view"` | default là schema kind, không phải business name | ✅ verify |
| 2 | Event offline 25 ngày vẫn bắn lên | Snowplow `maxEventStoreAge` mặc định 30 ngày | ✅ fix |
| 3 | 2 thiết bị chung 1 `session_id` | UUID seed **32-bit** thay vì 122-bit | ✅ verify |
| 4 | `session_index = 1917` | noti FCM rotate session | ✅ Android verify, ⏳ iOS chưa |
| 5 | 1 phiên bị tách 2 `session_id` | portal ưu tiên nhầm `client_session` | ✅ verify |
| 6 | `screen_end` không join được | Snowplow tự fire, thiếu `core_action` | ✅ verify |
| 7 | Thiếu `session_index` 15 | rotate lazily ngoài lifecycle hook | ✅ fix, ⏳ chưa verify |
| 8 | Session ma `529dc30d` | `screenViewAutotracking` mặc định `true` | ✅ fix, ⏳ chưa verify |
| 9 | Android không lên portal | endpoint trỏ `ftracking.fpt.vn` | ✅ đã đổi (chỉ để TEST) |

---

## Chi tiết

### 1. `event_action = "screen_view"` — `c768d08`, `3ea09da`

**Nguyên nhân:** `screenStartEventName` mặc định `"screen_view"` — đó là
**schema kind** (iglu parent gom `screen_viewed`/`screen_exited`/
`screen_load_completed`), không phải tên hành động. Config load bất đồng bộ nên
màn hình nào fire trước khi `initialize()` xong sẽ mang giá trị này.

Chỗ thứ hai: `resolveEventName(kind:defaultName:)` đọc `eventNames[kind]` — map
để resolve **SCHEMA name**. FPT Life đặt `event_names.screen_view =
"screen_view"` → đè mất default.

**Sửa:** default → `screen_viewed`/`screen_exited`. `action_name` thành hằng số
(`actionScreenViewed`/`ACTION_SCREEN_VIEWED`), **không** cho portal override.

**Verify:** 21.038 event trên portal — 0 lần xuất hiện `screen_view`.

### 2. Event cũ 25 ngày — `c893968`

**Nguyên nhân:** không truyền `EmitterConfiguration` → nhận default 30 ngày.
Event nằm trong SQLite tới khi flush thành công, mà `removeOldEvents()` chỉ chạy
**bên trong** `flush()`.

Đo thật: median lag device→collector **8,8 ngày**, max **25,4 ngày**.

**Sửa:** `maxEventStoreAge = 72h`. `maxEventStoreSize` giữ 1000.

### 3. Trùng `session_id` giữa 2 thiết bị — `f551b59`

**Nguyên nhân:** `std::mt19937_64 gen{std::random_device{}()}` — `random_device()`
trả **32-bit**. Không gian thật `2^32`, không phải `2^122`.

Nghịch lý sinh nhật: 50% trùng sau **77.163** session. Với 500k user × 5
session/ngày → trùng trong **43 phút**. Không phải xui, là chắc chắn.

Bằng chứng: `41ce987d` xuất hiện trên Vivo V2430 **và** Samsung SM-G996U1,
khác `device_id`, khác IP.

**Sửa:** đọc thẳng OS CSPRNG (`getentropy`/`getrandom`/`/dev/urandom`/
`BCryptGenRandom`). Nhánh fallback cũng rút đủ 64-bit seed.

**Verify:** 3000 process cold-start riêng biệt → 0 trùng. Sau fix: 500k user ×
10 session/ngày × 10 năm → P(trùng) ≈ `10^-16`.

### 4. Noti FCM đẻ session rác — `6390248`

**Nguyên nhân:** `load_from()` có guard `headless` nhưng **chỉ trong nhánh
`gap <= timeout`**. Push thường cách nhau hàng giờ → rơi vào nhánh `else`,
rotate vô điều kiện.

Bẫy thứ hai: khi thêm nhánh `else if (headless)`, phải stamp
`last_activity_ms_ = now`. Nếu khôi phục giá trị cũ thì `current_session_id()`
kế tiếp lại vượt timeout và **tự rotate**, hủy luôn guard vừa thêm.

**Verify:** `test_headless_no_rotate` — headless GIỮ session, user launch ROTATE.

### 5. Portal tách 1 phiên thành 2 session — portal `snowplow.js`

**Nguyên nhân:**
```js
if (/client_session/i.test(...)) clientSessionId = clientSessionId || c.data.sessionId;
if (/core_action/i.test(...))    clientSessionId = clientSessionId || c.data.session_id;  // KHÔNG BAO GIỜ CHẠY
```
`||` nên entity duyệt trước thắng. Với `screen_end` builtin, `client_session`
đứng trước `core_action` → portal lấy **sessionId của Snowplow**.

Đo: `7785b4db` (317 event) bị tách thêm `8ed47393` (76 event `screen_end`).

**Sửa:** biến riêng `coreActionSessionId`, ưu tiên
`sp.sid || coreActionSessionId || clientSessionId`.

> **Snowplow `client_session.sessionId` ≠ UniTrack `session_id`.** Luôn join
> theo `core_action.session_id`.

### 6. `screen_end` thiếu `core_action` — `b5d85b9`, `25fad50`

**Nguyên nhân:** Snowplow tự fire `screen_end` trong `ScreenSummaryStateMachine`,
SDK không gọi nên không chèn entity như `setScreen()` làm với `ScreenView`.

**Bẫy:** `event.entities` **rỗng** trong GlobalContext generator — Snowplow gắn
entity `screen` **sau khi** generator chạy. Đo: 76/76 event thiếu
`core_action.screen`. Phải lấy từ `UniTrack.previousScreenName()`.

**Sửa:** `GlobalContext(generator:filter:)` match theo schema `screen_end`.

### 7. Thiếu `session_index` 15 — `f3260ff`, `ff61151`

**Nguyên nhân:** `currentSessionId()` rotate **lazily**. Ai gọi đầu tiên sau
khoảng nghỉ dài thì người đó mở session — thường là screen event tự động, chạy
**trước** `applicationWillEnterForeground`. App chỉ phát `session_started` từ
lifecycle hook nên bỏ lỡ.

Đo: `f543d101` mang 56 event, **không có** `session_started` → query theo
`session_index` thấy trống ở 15.

**Sửa:** thêm `UniTrack.onSessionRotate(_:)` cả 2 platform. Seed baseline lúc
đăng ký (không fire cho session đang mở), truyền thẳng id vào handler (tránh đệ
quy vào chính accessor đang rotate).

### 8. Session ma `529dc30d` — `378bd18`

**Nguyên nhân:** `SnowplowOptions` bên Android **thiếu** field
`screenViewAutotracking`, mà Snowplow mặc định **`true`**
(`TrackerDefaults.kt:35`). iOS có set `false`, Android không.

Snowplow tự swizzle Activity → bắn `screen_view` thứ 2 mang tên class đầy đủ
(`vn.fpt.fsh.fptlife...StartingActivityDefault`) và **không có `core_action`**
→ portal không đọc được `session_id` → sinh session ma.

Đo 20/08: **20/65 (31%)** builtin `screen_view` là mồ côi.

**Sửa:** thêm field, default `false`, parity iOS.

### 9. Android không lên portal — chỉ đổi để TEST

Android bắn vào `ftracking.fpt.vn` (collector FPT), iOS bắn vào `mobix.asia`
(portal). Nên mọi session check trước giờ đều là iOS.

**Đã đổi** `snowplow.endpoint` + `snowplow.android.endpoint` sang portal.

> ⚠️ **PHẢI trả về `https://ftracking.fpt.vn` trước khi merge/release.**
> Backup: `/tmp/tracking_config-before-portal-endpoint.json.bak`

---

## Trạng thái repo

### SDK — đã push, đã tag

`unitrack-sdk` @ `debug/headless-session`, tag mới nhất **`0.3.60`**
(JitPack đã publish, `pom: 200`).

`unitrack-ios-package` @ `debug/hybrid-snowplow` — HEAD `ff61151`, đã push.

### App — CHƯA commit (theo rule không tự commit repo FPT Life)

**Android** `Ductt19/feat/mapping-ai-toggle` — 6 file sửa:
`tracking_config.json`, `FLifeApp.kt`, `FSDKTrackingConfig.kt`,
`FSDKTrackingEvents.kt`, `FSDKTrackingIdentity.kt`, `libs.versions.toml`.
Build: `:fpt-tracker` + `:app` compile SUCCESSFUL với `0.3.60`.

**iOS** — 5 file sửa: `AppDelegate.swift`, `FSDKTracking+Bootstrap.swift`,
`FSDKTracking+Events.swift`, `FSDKTracking.swift`, `trackingConfig.json`.

`stash@{0}` trên nhánh `integrate_tracking` vẫn còn, **chưa pop**.

---

## Việc còn lại

1. **Android chưa test runtime** — đã build được, chưa bắn event lên portal.
2. **iOS chưa có fix headless** (#4). SPM package dùng `load_from(path)` không
   có tham số `headless`. Khó hơn Android: iOS không có API tương đương
   `ActivityThread.mActivities`, phải dùng
   `UIApplication.shared.applicationState == .background` lúc
   `didFinishLaunching` — và cách này có điểm mù (mở từ lock screen cũng báo
   `.background` trong khoảnh khắc đầu).
3. **Phantom screen ~44%** (`screen_summary.foreground_sec = 0`): container VC
   lồng nhau khi chuyển tab — đo được 4 màn hình trong 16ms.
   **Đã chốt KHÔNG làm blocklist theo tên VC** (hardcode kiến trúc một app,
   không thuộc SDK dùng chung). Hai hướng còn mở: đội Data lọc
   `foreground_sec > 0`, hoặc SDK thêm `min_screen_dwell_ms` configurable
   mặc định 0.
4. **`screen_depth`** — field đội Data đề xuất để nhận diện session do noti.
   Hiện SDK **không có**. Field gần nhất `screen_count` chỉ nằm trong
   `session_ended`, mà session noti không bao giờ phát event đó (đo 264 session:
   **0** có `session_ended`). Đề xuất thay thế: stamp `entry_source`
   (`push`/`app_open`) vào **mọi** event.

---

## Cách verify

Trên VPS `root@103.188.83.49`:
```bash
./check_session.sh <session_id_prefix>   # bỏ trống = session mới nhất
```

Kết quả đúng:
```
BUILTIN screen_view  →  screen_viewed          (session_id CO, screen CO)
BUILTIN screen_end   →  screen_exited          (session_id CO, screen CO)
CUSTOM  screen_view  →  screen_load_completed
screen_summary: fg_sec có số
(không có dòng [!])
```

---

## Prompt mẫu cho session CLI sau

### Validate sau khi bắn event
```
Đọc docs/fli-tracking-fixes-2026-08.md để nắm bối cảnh.
Tôi vừa build app <Android|iOS> và bắn event lên portal.
SSH vào VPS chạy ./check_session.sh cho các session mới nhất, kiểm tra:
1. action_name có đúng screen_viewed / screen_exited / screen_load_completed
2. core_action có đủ session_id + screen không
3. Có session ma (event thiếu core_action) không
4. Có session 0-3 giây do noti không
5. Tỉ lệ phantom (foreground_sec = 0)
Báo cáo từng mục, chỗ nào sai thì nêu nguyên nhân và đề xuất.
```

### Làm tiếp việc còn lại
```
Đọc docs/fli-tracking-fixes-2026-08.md phần "Việc còn lại".
Làm việc số <N>. Trước khi sửa hãy trace code thật để xác nhận nguyên nhân,
đừng suy luận từ tài liệu. Sửa xong build cả 2 platform rồi báo tôi trước khi
commit/tag.
```

### Trả endpoint về production
```
Đọc docs/fli-tracking-fixes-2026-08.md mục 9.
Trả snowplow.endpoint + snowplow.android.endpoint trong
android-fptlife-fli/app/src/main/assets/tracking_config.json
về https://ftracking.fpt.vn. Backup ở /tmp/tracking_config-before-portal-endpoint.json.bak
```

### Điều tra một session cụ thể
```
Đọc docs/fli-tracking-fixes-2026-08.md và docs/screen-tracking-contract.md.
Check session #<id> trên portal VPS. Nếu thấy bất thường, trace từ source SDK
(unitrack-sdk) và source app (android-fptlife-fli / FPT-Life-FLI) để tìm
nguyên nhân gốc — không đoán.
```

### Quy tắc luôn áp dụng
```
- KHÔNG tự commit trong FPT-Life-FLI và android-fptlife-fli, chỉ sửa file.
- Build PASS trước khi tag SDK hoặc push SPM package.
- Verify bằng dữ liệu thật trên portal, không tin build-pass là xong.
- iOS app build từ unitrack-ios-package (SPM), KHÔNG phải unitrack-sdk.
  Sửa ở unitrack-sdk phải port sang package thì app mới nhận.
- Android build từ JitPack — phải TAG mới có artifact, push branch không đủ.
```
