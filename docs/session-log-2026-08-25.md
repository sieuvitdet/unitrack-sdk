# Tổng hợp thay đổi — UniTrack SDK + FPT Life (25/08/2026)

Phiên bản SDK: **0.3.77 → 0.3.81**. Toàn bộ phiên xoay quanh một chủ đề: làm
sạch nhóm event màn hình (`screen_view` / `screen_end` /
`screen_load_completed`) trên iOS. Mọi kết luận đều truy từ dữ liệu thật trên
VPS (project 8, iPhone 15 Pro), không suy từ code.

Nối tiếp [session log 20–21/08](./session-log-2026-08-20-21.md).

---

## 1. Bối cảnh: 4 vấn đề phát hiện từ dữ liệu thật

| # | Vấn đề | Nguồn | Trạng thái |
|---|---|---|---|
| 1 | 16 event container rác mỗi lần mở app | session `d36eaf25` | ✅ 0.3.78 |
| 2 | `screen_name` lệch một nhịp so với entity | session `d36eaf25` | ✅ 0.3.78 |
| 3 | `screen_load_completed` bắn 2 lần / màn | session `496552f3` | ✅ 0.3.79 |
| 4 | `load_time_ms` báo 85 giây | session `6fda62c3` | ✅ 0.3.80 + 0.3.81 |

Cả 4 đều là lỗi **thật của SDK**, không phải lỗi test hay môi trường.

---

## 2. Container rác — lọc bằng hành vi, không bằng tên class (0.3.78)

### Triệu chứng

Session `d36eaf25` (09:53): bro chỉ mở app, chưa chạm gì → **28 event trong
10 giây**. Trong đó 16 event là cặp `screen_view` + `screen_end` với
`foreground_sec = 0`:

```
09:53:56.237  screen_view  FSSHomeTabBarViewController
09:53:56.240  screen_end   FSSHomeTabBarViewController    fg=0   ← sống 3ms
09:53:56.241  screen_view  MainHomeViewController
09:53:56.243  screen_end   MainHomeViewController         fg=0   ← sống 2ms
```

Cụm này còn lặp lại 2 lần. Đây là các VC container của tab bar, đi qua
`viewDidAppear` trong lúc dựng cây view — người dùng chưa từng nhìn thấy chúng.

### Ba hướng đã cân nhắc

| Hướng | Vì sao loại |
|---|---|
| Blocklist tên class | Nhét tên VC của FPT Life vào SDK dùng chung là sai chỗ. Mỗi app mới lại phải release. Đổi tên class là hỏng thầm lặng. |
| Blocklist đọc từ portal | Vẫn phải **biết trước** tên VC. App mới luôn bẩn đợt đầu. Là giải pháp vá. |
| **Settle window** ✅ | Phân biệt bằng hành vi, không cần biết tên gì. |

### Cách làm

Dữ liệu tách rất sạch — rác luôn `fg = 0`, màn thật luôn `> 0`:

| | `foreground_sec` |
|---|---|
| `FSSHomeTabBar`, `MainHome`, `AppTabBarPager` | `0, 0` |
| `HomeAllDevice` | `0.89, 0.2` |
| `ISCFlashScreen` | `6.35` |

Nên: hoãn emit qua một cửa sổ, **chỉ bắn nếu không có VC nào appear đè lên
sau đó**. VC bị đè trong cửa sổ chưa từng hiện cho người dùng thấy — theo
định nghĩa nó không phải màn.

```swift
ViewControllerSwizzler.appearSeq &+= 1
let mySeq = ViewControllerSwizzler.appearSeq
DispatchQueue.main.asyncAfter(deadline: .now() + settleWindow) {
    guard ViewControllerSwizzler.appearSeq == mySeq else { return }  // bị đè → bỏ
    ...
}
```

Cửa sổ 50ms này **đã tồn tại sẵn** cho manual-priority arbitration (nhường
DEV gọi `setScreen` trước). Nó chỉ gánh thêm việc lọc container — không thêm
timer mới.

Android dùng `afterSettle()` với **một bộ đếm chung cho Activity lẫn
Fragment** — chúng đè lên nhau trong cùng luồng dựng UI nên đếm riêng sẽ lọc
sai.

Chỉnh được qua portal `sdk_config.screen_settle_ms` (0 = tắt lọc).

### Sửa kèm: `screen_name` lệch một nhịp

Cùng session, `payload.screen_name` và `entity.screen.name` **không khớp một
dòng nào**:

| `payload.screen_name` | `entity.screen.name` |
|---|---|
| `HomeAllDeviceViewController` | `ISCFlashScreenSyncDataViewController` |
| `FSSHomeTabBarViewController` | `HomeAllDeviceViewController` |

Gốc: `setScreen` bị defer 50ms còn `screen_load_completed` bắn **ngay**. Khi
nhiều VC xuất hiện dưới 50ms, Snowplow gắn entity `screen` của VC trước đó.

Fix: chuyển `screen_load_completed` vào **cùng closure**, bắn **sau**
`setScreen`. `load_ms` vẫn đo tại thời điểm appear thật, chỉ hoãn việc *gửi* —
đo trong closure sẽ cộng oan 50ms vào mọi màn.

---

## 3. `screen_load_completed` bắn 2 lần cùng màn (0.3.79)

### Triệu chứng

Session `496552f3` (11:27):

```
11:27:08.041  CameraHomeViewController  load=29   ┐ cách 1.45 giây
11:27:09.491  CameraHomeViewController  load=2    ┘
```

`ttff` khác nhau (29 vs 2) → **hai instance khác nhau**, không phải SDK gửi
trùng. Cờ `ut_loadReported` là associated object per-instance nên không chặn
được, và settle window 50ms cũng không (cách nhau quá xa).

### Gốc phía app

`FSSHomeViewController.swift` gọi `createAllTab()` ở **hai chỗ**:

- Dòng 60 — lúc dựng UI (`lazy var tabBarView`)
- Dòng 165 — khi API `items` về, `setControllers()` thay **toàn bộ** mảng

Tab "all" bị dựng lại dù không đổi gì. 1.45 giây chính là thời gian API trả về.

### Nhưng SDK vẫn phải sửa

Người dùng chỉ thấy **một màn liên tục** — bằng chứng: **không có `screen_end`
nào giữa hai event**. So với chuyển màn thật thì luôn có:

```
32028030  screen_end   HomeAllDevice   fg=55.37
32028038  screen_view  CameraHome                ← boundary thật
```

Lần dựng thứ hai đo thời gian *thay VC*, không đo trải nghiệm của ai.

### Cách làm

`setScreen` **đã có sẵn** dup guard đúng cho việc này (`isSameScreen`) — đó là
lý do dữ liệu chỉ có **một** `screen_view` builtin chứ không phải hai. Chỉ
riêng `screen_load_completed` nằm ngoài nó.

Cho `setScreen` **trả về** cờ dup thay vì để caller tự so tên — một nguồn sự
thật cho "màn có đổi không":

```swift
let sameScreen = UniTrack.setScreen(screen, layer: .iOSNative)
guard !sameScreen else { return }
```

Android: `setScreenReportingDup()`. Quay lại cùng màn **sau** `screen_end` vẫn
tính bình thường — đó là boundary thật.

---

## 4. `load_time_ms` báo 85 giây (0.3.80 → 0.3.81)

Đây là chỗ tôi sửa **hai lần** vì lần đầu chưa đủ.

### Vòng 1 (0.3.80) — VC được giữ lại

Session `6fda62c3`: `CameraHomeViewController` báo `load=85764`.

Truy ngược: VC tạo ở `+10098ms`, người dùng rời đi xem live 85 giây, quay lại
ở `+95862ms`. VC không bị hủy nên **`viewDidLoad` không chạy lại**, mốc cũ vẫn
nguyên → `load_ms` cộng luôn quãng nằm chờ.

Fix: swizzle thêm `viewWillAppear` để re-arm mốc cho VC đã từng hiện. Lần đầu
không đụng — `viewWillAppear` chạy ngay sau `viewDidLoad` nên ghi đè sẽ nuốt
mất chính phần dựng view cần đo.

**Android mắc bệnh khác nhưng cùng gốc:** `createdAtMs.remove()` ở `onResume`
khiến lần quay lại `createdAt = null` → **mất hẳn** `load_ms` thay vì sai số.
Đây là lỗi chưa từng lộ trên portal vì Android đang đi ngrok.

### Vòng 2 (0.3.81) — VC nằm chờ giữa will và did

Session `e456c802` vẫn còn `load=5091`. Truy ngược: `viewWillAppear` ở `+9695`
mà `viewDidAppear` mãi `+14786`.

Giả định của vòng 1 — *"will luôn được nối bằng did ngay sau"* — **sai**.
Pager dựng sẵn trang kế, hoặc chuyển màn bị hủy giữa chừng, thì VC nằm chờ
hàng giây.

Fix: bỏ cờ trạng thái, dùng một phép max, mốc `will` cập nhật **mỗi lần**:

```swift
let anchor = max(ut_loadStart, ut_willAppearAt)
```

Ba trường hợp tự đúng:

| | Mốc thắng | Kết quả |
|---|---|---|
| Lần đầu | `loadStart` (will chỉ sau vài ms) | đo cost dựng view |
| Hiện lại | `willAppearAt` | không cộng 85 giây đi vắng |
| Nằm chờ | `willAppearAt` lần cuối | không cộng 5.1 giây chờ |

Đơn giản hơn vòng 1: xóa được `ut_loadReported` (không còn ai đọc, chỉ còn
ghi) và bỏ `[weak self]` không dùng tới. Android cùng công thức qua
`activityStartedAtMs` / `startedAtMs` (`onStart`).

---

## 5. Kết quả đo — trước và sau

Đối chiếu session `d36eaf25` (09:53, trước fix) với `e456c802` (15:37, sau
0.3.80):

| | Trước | Sau |
|---|---|---|
| Container rác `fg=0` | **16 event** | **0** |
| `screen_name` lệch entity | 4/7 lệch | **0/12 lệch** |
| `screen_load_completed` trùng | 2 cặp | **0** |
| `load_time_ms` bất thường | 85764 | 5091 → đã sửa ở 0.3.81 |

`load_time_ms` sau 0.3.80 (session `e456c802`):

| Màn | Các lần đo |
|---|---|
| `LiveViewController` | 689, 564, 562, 493, 603 |
| `CameraHomeViewController` | 20, ~~5091~~, 502, 508, 530 |
| `EventManagementViewController` | 582 |

`LiveViewController` vào ra 5 lần, cụm quanh 500–690ms — ổn định.

Thứ tự `screen_end` → `screen_view` chuẩn từng cặp, `foreground_sec` khớp
thời gian thao tác thật.

---

## 6. Hai câu hỏi về field, và một phát hiện

### `dwell_ms` là gì

Tổng thời gian màn được mở, tính wall-clock ở `core/src/tracker.cpp:181`:

```cpp
dwell_ms = now - screen_entered_at_ms_;
```

**Nó tính cả thời gian app ở background.** Mở màn A, bấm home 2 tiếng, mở lại
rồi sang màn B → `dwell_ms` của A là 2 tiếng. Comment trong code nói thẳng:
*"để quên tab 2 tiếng trông y hệt đọc 2 tiếng"*.

Nên SDK bắn kèm hai field tách tổng đó ra:

| Field | Ý nghĩa |
|---|---|
| `dwell_ms` | **Tổng** thời gian màn được mở (legacy) |
| `foreground_sec` | Số giây màn **thực sự hiển thị** |
| `background_sec` | Số giây màn nằm dưới nền |

### `is_exit_screen` là gì

Cờ phân biệt "rời màn" với "rời app". Chỉ **một chỗ** trong SDK set `"true"` —
`AppLifecycleObserver` khi bắt `didEnterBackground`, kèm
`reason = "app_backgrounded"`. `setScreen()` luôn set `"false"`.

Không có nó thì "chuyển sang màn khác" và "thoát app tại đây" trông giống hệt
nhau — đội data không biết người dùng bỏ app ở màn nào.

### Phát hiện: FPT Life **không nhận** cả ba field này

Kiểm dữ liệu thật project 8: **137 `screen_end`**, nhưng
**0 event** mang `dwell_ms`, **0 event** mang `is_exit_screen`.

Nguyên nhân — hybrid mode, `SnowplowProvider.swift:452`:

```swift
if hybridScreenView,
   name == "screen_viewed" || name == "screen_view" || name == "screen_exited" {
    return   // chặn path custom vendor
}
```

`screen_exited` bị chặn khỏi custom vendor để tránh đếm đôi (comment ghi số đo
thật: session `7785b4db` có 77 builtin vs 76 custom). Nó đi qua builtin
`com.snowplowanalytics.mobile/screen_end`, mà schema đó chỉ có entity
`screen_summary` với `foreground_sec` + `background_sec`.

**`dwell_ms`, `is_exit_screen`, `reason` bị bỏ lại.**

Hệ quả: đội data hiện phải suy gián tiếp "thoát ở màn nào" bằng cách lấy
`screen_end` cuối cùng của mỗi `session_id` — kém chính xác nếu event cuối mất
do mạng.

**Chưa sửa.** Cách sạch nhất là nhét `is_exit_screen` + `reason` vào entity
`core_action` (entity này đã đi kèm mọi event kể cả builtin, nên không đụng
schema `screen_end`). Chờ quyết định.

---

## 7. Thay đổi phía hạ tầng

### Config endpoint

| Thời điểm | Android | iOS |
|---|---|---|
| Đầu phiên | ngrok `4ffa-…` | ngrok `4ffa-…` |
| Giữa phiên | ngrok `55d0-…` (5 key) | — |
| Cuối phiên | ngrok `55d0-…` | **portal mobix** (6 key) |

iOS được trả về portal để tôi kiểm được dữ liệu. Android vẫn đi ngrok →
**tôi không kiểm được data Android** trong phiên này.

Backup: `/tmp/tc.bak2` (Android ngrok cũ), `/tmp/tc-ios-ngrok.bak` (iOS ngrok).
Backup `/tmp/tc-ios.bak` từ phiên trước đã bị `/tmp` dọn mất — URL portal lấy
lại từ config Android (flavor `uat` còn nguyên).

### Dọn dữ liệu VPS

Project 8 từ **1184 event / 88 session** → **205 event / 6 session**. Xóa 979
event của 21–22/08 (test cũ), giữ nguyên 25/08.

Backup: `events.db.bak-before-clear-20260825-070855` (61MB).

### Sửa kèm: header iOS lệch phiên bản

`platforms/ios/Sources/UniTrackCore/include/unitrack.h` là **file thật** commit
từ 25/06, trong khi `CoreVendor` được sync tự động → nó tụt hậu và làm build
fail với `cannot find 'ut_last_end_reason'`. Lỗi **có sẵn từ trước**, không do
thay đổi phiên này.

Đổi thành symlink trỏ vào core, giống `src` bên cạnh vốn đã là symlink.

---

## 8. Còn treo

1. **`first_frame` bắn 2–3 lần** — lỗi app, `AppLiveStreamView.swift:856`.
   Guard `!self.isReadyToPlay` đọc cờ **trước** khi `liveBeginStream()` bật
   cờ đó, mà việc bật lại nằm trong một `DispatchQueue.main.async` **lồng
   thêm**. Nhiều frame đầu cùng thấy cờ `false` → cùng bắn. Session
   `6fda62c3` có chỗ bắn **ba lần**. Tái hiện đều đặn mỗi lần mở live.
   `camera_stream_started` cũng bị đôi, cùng cơ chế.
   **Bro đã quyết bỏ qua.**

2. **Tab "all" bị dựng lại vô ích** — `FSSHomeViewController.swift:165`. SDK đã
   thôi báo cáo (0.3.79) nhưng app vẫn tốn một lần khởi tạo VC mỗi lần API về.
   Fix một dòng: dùng lại `self.allCameraPlayable` thay vì `createAllTab()`.
   Dòng 165 còn viết `self.self.createAllTab()` — không lỗi nhưng là dấu hiệu
   code sửa vội.

3. **`dwell_ms` / `is_exit_screen` không lên wire FPT Life** — xem §6.

4. **Android chưa verify** — đang đi ngrok nên không kiểm được data. Bản sửa
   Android (settle window, dup guard, `startedAtMs`) đã build PASS nhưng **chưa
   có số đo thật nào**.

5. **`load_time_ms` chưa verify 0.3.81** — session `e456c802` là bản 0.3.80.
   Cần build lại với 0.3.81 để xác nhận `load=5091` biến mất.

---

## Phụ lục: bản đồ version

| Tag | Nội dung |
|---|---|
| 0.3.78 | **Settle window** lọc container + sửa `screen_name` lệch nhịp |
| 0.3.79 | `screen_load_completed` chỉ tính **lần vào màn**, không phải mỗi VC |
| 0.3.80 | `load_ms` re-arm ở `viewWillAppear` / `onStart` |
| 0.3.81 | `load_ms` lấy **mốc muộn nhất** — bỏ luôn quãng VC nằm chờ |

Cả 4 tag đều lên JitPack `status: ok` (2 module) và SPM (build verify PASS
trước khi tag, theo rule bắt buộc).

Kiểm thử: `core/tests/test_screen_settle.py` — **15/15 PASS**. Gồm replay đúng
mốc ms thật của 3 session: `d36eaf25`, `496552f3`, `e456c802`.

### Một kỳ vọng test sai đã bị chính test bắt

Ban đầu tôi viết `test_full_session_replay` kỳ vọng `HomeAllDevice` còn 2 lần,
thực tế là 3 — nó sống 890ms rồi 202ms giữa các cụm container, khớp `fg=0.89`
và `fg=0.2` trên VPS. **Lỗi kỳ vọng của test, không phải lỗi code.**
