# Session log 02–04/09/2026 — SDK 0.3.81 → 0.3.87

Phiên này bắt đầu từ một câu hỏi về hybrid screen view, kết thúc ở việc phát
hiện app tự xoá dữ liệu SDK. Bảy tag phát hành, trong đó một tag hỏng phải bỏ.

| Tag | Commit | Nội dung |
|---|---|---|
| `0.3.82` | `8f924c6` | `screen_exited` chỉ skip khi builtin thật sự thay nó |
| `0.3.83` | `302bd5a` | `fsync` state file |
| `0.3.84` | `9c036d0` | Đồng hồ đơn điệu cho mọi phép đo thời lượng |
| `0.3.85` | `0799d49` | Bất biến không-âm — **BUILD HỎNG, BỎ** |
| `0.3.86` | `39762ae` | Ép kiểu `std::max`, sửa build Android |
| `0.3.87` | `c036401` | `detectHeadlessLaunch` luôn trả true |

Kèm `a5966e7` (portal, không tag): hiện iOS/Android thay vì `mob`.

---

## 1. Đổi hướng: chỉ `screen_viewed` dùng builtin

Trước đó cả vào màn lẫn rời màn đều chuyển sang builtin Snowplow. Chốt lại:
**chỉ vào màn dùng builtin**, rời màn giữ custom vendor như cũ.

### Cách thực hiện

Builtin `screen_end` **không phải do SDK gọi** — Snowplow tự sinh nó kèm mỗi
`ScreenView`. Bỏ guard chỉ khiến custom đi qua, còn builtin vẫn bắn → đếm đôi.
Muốn tắt phải gỡ cỗ máy sinh ra nó:

```swift
// Tracker.swift:159-169
var screenEngagementAutotracking: Bool {
    set {
        if newValue { self.addOrReplace(stateMachine: ScreenSummaryStateMachine()) }
        else { _ = self.stateManager.removeStateMachine(ScreenSummaryStateMachine.identifier) }
    }
}
```

Đặt cờ này `false` là xong. **Không ảnh hưởng `screen_viewed` builtin** — hai
state machine hoàn toàn độc lập:

| Cờ | State machine | Chịu trách nhiệm |
|---|---|---|
| `screenContext` (giữ bật) | `ScreenStateMachine` | Entity `screen` |
| `screenEngagementAutotracking` (tắt) | `ScreenSummaryStateMachine` | `screen_end` + `screen_summary` |

### Bug phát sinh và cách sửa (0.3.82)

Guard trong `track()` skip `screen_exited` vô điều kiện với giả định "builtin
đã lo". Khi tắt cờ engagement thì builtin không còn sinh nữa → **builtin không
bắn, custom bị chặn, mất trắng cả event**.

Đo thật session `67826fc8`: 30 `screen_viewed`, **0 `screen_exited`**.

Guard giờ đòi thêm `options.screenEngagementAutotracking` cho riêng nhánh
`screen_exited`. Sau fix, session `d5f25e7c` cân **17:17**, Android
`baafb60c` cân **13:13**, cả hai **0 builtin `screen_end`**.

> Không bỏ hẳn `screen_exited` khỏi guard: làm vậy tái tạo lỗi đếm đôi 1:1 đã
> đo ở session `7785b4db` (77 builtin vs 76 custom).

---

## 2. Bất biến: SDK không bao giờ gửi thời gian âm (0.3.84–0.3.86)

### Bug gốc

`dwell_ms = -9.544.502` trên iPhone thật. CSV session `0eeaebfc`, 02/09:

| | Đồng hồ máy | Đồng hồ server |
|---|---|---|
| Vào màn splash | `11:59:03.156` | `04:30:40.860` |
| Rời cùng màn đó | `09:19:58.653` | `09:43:23.840` |

Máy ghi rời màn **sớm hơn** vào màn 2h39. Hiệu số `-9.544.503ms`, lệch đúng
1ms so với giá trị báo cáo.

Cột `dvce_sent_tstamp` cho thấy chính xác thời điểm nhảy: dòng 1 tạo và gửi
cách nhau 3ms (đồng hồ máy thật sự là `11:59`), dòng 2 `created` vẫn `11:59`
nhưng `sent` đã thành `04:30` — đồng hồ được chỉnh **giữa lúc tạo và gửi**.

Lệch **7h59'37"**, không tròn 8 tiếng nên không phải lỗi múi giờ. Máy đặt
`Asia/Ho_Chi_Minh`. Đây là đồng hồ hệ thống sai thật rồi được NTP kéo về.

### Hai lớp phòng vệ

**Lớp 1 — nguồn thời gian đúng:**

| Nền tảng | API |
|---|---|
| Core C++ | `monotonic_ms()` — `steady_clock` |
| iOS | `CACurrentMediaTime()` |
| Android | `SystemClock.elapsedRealtime()` |
| Web | `monoNow()` — `performance.now()` |

**Lớp 2 — guard `max(0, ...)` ở mọi phép trừ**, kể cả chỗ đã dùng monotonic.
Đây là bất biến, phải giữ được cả khi refactor sau này đổi lại nguồn thời gian.

### Lỗ nghiêm trọng nhất

`session_end.duration_ms` (`tracker.cpp:390-394` sau fix) — hai mốc **bắt buộc** wall clock
vì đọc từ `session.json` của process trước, mà monotonic reset mỗi lần chạy.
Nghĩa là nó **âm được mà không cần đồng hồ nhảy**: user chỉ cần đổi timezone
giữa hai lần mở app. Đi qua core nên âm được trên **cả bốn nền tảng**.

Kèm trường hợp mốc bằng 0 (state file cũ/cụt) làm hiệu ra ±1.7e12.

### Guard tại core, không phải từng binding

`duration_ms` mạng và `cold_start_ms` là tham số binding truyền vào. Kẹp
`std::max` ngay trong core che cho **mọi binding**, kể cả React Native và
Flutter đang dùng bản core đóng băng từ 22/06.

### Chỗ cố ý giữ wall clock

| Vị trí | Lý do |
|---|---|
| `session_manager.cpp` timeout 30' | `last_activity_ms_` persist ra đĩa, không có trục chung giữa hai process |
| `offline_queue.cpp` TTL | Nhiều ngày trong SQLite |
| `e.timestamp_ms` | Timestamp lên wire |
| iOS `AppLifecycleObserver:181` | Phải **khớp pha với core**: máy ngủ 35 phút thì mono không cộng khoảng ngủ, core đã rotate mà Swift tưởng phiên còn sống |

Với chỗ cuối, tôi tách `backgroundedAtMono` riêng cho bộ đếm, giữ
`backgroundedAt` (wall) cho phép so timeout.

### Tag 0.3.85 hỏng

```
tracker.cpp:389 (trước fix): error: no matching function for call to 'max'
  deduced conflicting types ('long long' vs. 'int64_t' (aka 'long'))
```

`int64_t` là `long` trên Android 64-bit nhưng `long long` trên macOS. Build
local bằng `clang++ -fsyntax-only` không lộ ra vì ở đó hai kiểu trùng nhau.

**Bài học:** thay đổi ở core phải build bằng
`./gradlew :unitrack:externalNativeBuildRelease` (NDK thật), không chỉ kiểm cú
pháp trên macOS.

---

## 3. `detectHeadlessLaunch` luôn trả true (0.3.87)

Hàm dò headless soi `ActivityThread.mActivities` qua reflection, coi map rỗng
là "process bị FCM đánh thức". Giả định nền tảng **sai**: activity record chỉ
được tạo **sau** khi `Application.onCreate()` trả về, mà SDK khởi tạo **trong**
`onCreate()` → map luôn rỗng → mọi lần user mở app đều bị coi là headless.

Ba bằng chứng:

- Toàn bộ event Android mang `is_headless=true`, kể cả phiên 36 event có
  camera stream
- **0 event `app_start`** (`tracker.cpp:433` thoát sớm khi headless)
- Cùng lúc **iOS báo `is_headless=false`** trên đúng project đó

Thay bằng `ActivityManager.RunningAppProcessInfo.importance` — API công khai,
có giá trị đúng ngay tại `onCreate()`. `IMPORTANCE_FOREGROUND` (100) = user mở
app; process đánh thức nền có importance cao hơn hẳn (SERVICE=300, CACHED=400).

Sau fix, logcat cho `is_headless: false` và `session_index: 3` đúng chuỗi.

---

## 4. Nguyên nhân thật của `session_index` reset — KHÔNG phải bug SDK

### Triệu chứng

`session_index` reset về 1 liên tục dù user không gỡ app:

```
09:45:46  bae38f67  index=4  prev=82c1e29b
09:45:54  507f4e68  index=1  prev=(rỗng)   ← cách 8 GIÂY
```

Tám giây thì file không thể mất vì lỗi ghi.

### Nguyên nhân

`RogoSmartService.onCreate()` gọi `FileCache.clearApplicationData` và quét sạch
**7 thư mục**:

```
app_flutter, cache, code_cache, databases, files, no_backup, shared_prefs
```

Logcat bắt được nó xoá thẳng file của SDK:

```
D LOGR: DEBU: FileCache deleteFile:  unitrack_queue.db
D LOGR: DEBU: FileCache deleteFile:  unitrack_queue.db-wal
D LOGR: DEBU: FileCache deleteFile:  unitrack_queue.db-shm
```

Kiểm trực tiếp trên máy: `files/` **không có `session.json` lẫn
`unitrack_queue.db`**. Trước đó vài giờ file còn 214 byte hợp lệ.

Chạy **7 lần** trong một đợt log, mỗi lần app khởi động.

### Điều này giải thích mọi thứ

| Hiện tượng | Lời giải |
|---|---|
| Hai session cách 8 giây, index 4 rồi 1 | `RogoSmartService` xoá file giữa hai lần |
| Session sống 10 phút, 12 noti, vẫn index=1 | Ghi state bình thường, lần sau file đã bị xoá |
| Lúc mở bằng launcher lại được index=3 | Bắt đúng khoảnh khắc giữa hai lần dọn |
| Vì sao `fsync` không giải quyết được | Ghi hoàn hảo cũng vô nghĩa nếu bị xoá ngay sau |

### Ảnh hưởng rộng hơn UniTrack

`clearApplicationData` xoá dữ liệu của **mọi** thư viện trong app. Log cho thấy
Crashlytics cũng bị (`com.crashlytics.settings.json`, `report`, `start-time`).

### Ba hướng xử lý

**A — Sửa `FileCache` chừa file không phải của Rogo.** Đúng gốc nhất, nhưng
nằm trong SDK bên thứ ba.

**B — Đổi chỗ lưu của UniTrack.** Lưu ý `no_backup` cũng bị xoá, phải tìm chỗ
khác.

**C — Chặn `RogoSmartService` chạy dọn dẹp** nếu không thực sự cần.

---

## 5. Ba chẩn đoán sai của tôi

Cần ghi lại vì cùng một nguyên nhân: **suy từ dữ liệu đã tổng hợp thay vì kiểm
máy thật, dù máy cắm sẵn**.

| Lần | Chẩn đoán | Thực tế |
|---|---|---|
| 1 | Thiếu `fsync` | Ghi vốn đã tốt |
| 2 | `detectHeadlessLaunch` sai | Đúng là bug, nhưng không gây index reset |
| 3 | Đa tiến trình / init lỗi | Không phải |

Chỉ cần một lệnh `adb shell run-as ... ls files/` là ra ngay từ đầu.

Ngoài ra tôi còn báo cáo vội hai lần khi chỉ nhìn 2 session đầu mà không lọc
theo `is_headless` — trong khi chính tôi đã dùng cột đó ở các lượt trước.

Hai fix `0.3.83` và `0.3.87` vẫn đáng giữ: chúng sửa bug thật, chỉ không phải
bug này.

---

## 6. Việc chưa làm

| Việc | Mức | Lý do |
|---|---|---|
| Đồng bộ core cho RN + Flutter | **Cao** | Bản sao đóng băng từ 22/06, còn nguyên lỗi UUID 2³² và wall clock |
| Xử lý `RogoSmartService` xoá file | **Cao** | Chặn `session_index` hoạt động đúng |
| Báo team app lỗi NPE | **Cao** | `RogoSmartService.subcribeNotificationIfNeed` đọc `UserExtra` null → app chết |
| Sửa hot-reload `updateUserContext` | Thấp | Bug ngủ đông — generator đã tắt |
| Dọn code chết | Thấp | `exitingScreen`, `makeScreenEndContext()` |

### Rủi ro tồn đọng

**Session headless index=1.** 31 session notification đều `index=1`, chưa rõ
do `RogoSmartService` xoá file hay tiến trình FCM không đọc được state. Cần
tách bạch sau khi xử lý việc xoá file.

**Notification sinh session rác.** 31/40 session là headless. Đây là quyết định
product owner 21/08 ("mỗi tiến trình mới là một phiên mới"), phân biệt bằng
`is_headless`. Muốn đổi cần xác nhận lại với người quyết.

---

## 7. Portal

`a5966e7` — danh sách session hiện iOS/Android thay vì `mob`.

Field `p` của Snowplow chỉ có ba giá trị `mob`/`web`/`srv` nên theo thiết kế
không phân biệt được. Nhưng `snowplow.js` **đã** lift sẵn OS từ
`application_context` để dùng cho cột device — chỉ là lúc build row lại lấy
`sp.p`. Fix một dòng.

Kết quả: `ios 119 / android 50 / mob 49 / web 3` → `ios 168 / android 50 / web 6`.
Độ phủ 1504/1505 (99,93%).

**Phát hiện kèm:** bản `snowplow.js` trên VPS **mới hơn repo** — chứa fix
`coreActionSessionId` chưa bao giờ sync về git. Suýt bị ghi đè. Quy trình đang
sửa thẳng trên VPS rồi quên đưa về repo, đáng rà lại.

Cũng sửa `duration_ms` âm trong `app_sessions` (`agent.js:180`): `started_at`
và `ended_at` đến từ hai nguồn khác nhau nên clock skew lọt qua. Guard
`Math.max(0,…)` + backfill 11 dòng cũ.

> Lưu ý kỹ thuật: `portal/agent.js` bị hệ thống nhận là **binary**, `grep`
> thường im lặng bỏ qua. Phải dùng `grep -a`.

---

## 8. Trả lời vài câu hỏi trong phiên

**`session_id` sinh thế nào?** SDK định nghĩa hình dạng (đóng dấu 6 bit theo
RFC 4122 thành UUID v4), hệ điều hành cung cấp 16 byte ngẫu nhiên qua CSPRNG:
`arc4random_buf` (iOS), `getrandom(2)` (Android). Bug cũ là SDK tự sinh bằng
`mt19937_64` gieo từ 32-bit → không gian thật chỉ 2³².

**`event_id` trùng trong CSV?** Không phải bug SDK. Nó do Snowplow sinh bằng
`UUID()` của Foundation, chưa bao giờ đi qua code UniTrack. Ba dòng trùng là
**cùng một event gửi lại ba lần** — `dvce_created_tstamp` giống hệt tới từng
mili giây. Xử lý bằng khử trùng ở warehouse, không sửa cơ chế retry (nó đang
chạy đúng, và chính nó đảm bảo không mất dữ liệu khi offline).

**Portal còn dùng làm nguồn config không?** Không. Từ nay portal chỉ là nơi
bắn event lên để test. Config lấy từ JSON đóng gói trong app. Hệ quả: đổi
config phải build lại app, và bug hot-reload `updateUserContext` hạ ưu tiên.
