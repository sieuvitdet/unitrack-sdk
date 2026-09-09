# UniTrack Web SDK — hướng dẫn tích hợp

SDK thu thập hành vi người dùng trên web và gửi lên Snowplow collector. Toàn bộ
cấu hình nằm trong một file JSON; code ứng dụng chỉ gọi vài hàm.

- [1. Cài đặt](#1-cài-đặt)
- [2. File cấu hình](#2-file-cấu-hình)
- [3. Khởi tạo](#3-khởi-tạo)
- [4. Gắn tracking vào code](#4-gắn-tracking-vào-code)
- [5. Event SDK tự bắt](#5-event-sdk-tự-bắt)
- [6. Định danh người dùng](#6-định-danh-người-dùng)
- [7. Session](#7-session)
- [8. Consent và quyền riêng tư](#8-consent-và-quyền-riêng-tư)
- [9. Plugin tuỳ chọn](#9-plugin-tuỳ-chọn)
- [10. Cross-domain](#10-cross-domain)
- [11. Tham chiếu cấu hình](#11-tham-chiếu-cấu-hình)
- [12. Payload gửi đi](#12-payload-gửi-đi)
- [13. Debug](#13-debug)
- [14. Lỗi thường gặp](#14-lỗi-thường-gặp)

---

## 1. Cài đặt

**Qua npm:**

```bash
npm install unitrack-web
```

```js
import UniTrack from 'unitrack-web';
```

**Qua thẻ `<script>`** — SDK gắn biến toàn cục `UniTrack`:

```html
<script src="/js/unitrack.iife.js"></script>
```

Bundle nằm ở `dist/unitrack.iife.js` (IIFE), `dist/unitrack.esm.js` (ESM),
`dist/unitrack.cjs.js` (CommonJS).

---

## 2. File cấu hình

Đặt `unitrack.config.json` ở thư mục public để trình duyệt tải được qua HTTP.
Đây là file mẫu đầy đủ:

```json
{
  "version": 1,
  "endpoint": "",
  "pii_salt": "doi_chuoi_nay_thanh_salt_rieng",
  "sdk_config": {
    "autoCapture": true,
    "trackScreens": true,
    "trackTaps": true,
    "trackNetwork": true,
    "trackLifecycle": true,
    "batchSize": 10,
    "flushIntervalMs": 3000,
    "sessionTimeoutMs": 1800000,
    "sampling_rate": 1.0,
    "require_consent": false,
    "screen_start_event": "screen_viewed",
    "screen_end_event": "screen_exited",
    "logLevel": "warn",
    "verboseLogging": false
  },
  "snowplow": {
    "enabled": true,
    "endpoint": "https://collector.example.com",
    "appId": "ma_app_cua_ban",
    "iglu_vendor": "vn.fpt.ftel.snowplow",
    "default_version": "1-0-0",
    "event_names": {
      "click": "ev_click",
      "result": "ev_result",
      "screen_view": "screen_view",
      "screen_end": "screen_end",
      "crash": "ev_crash",
      "api": "ev_api",
      "session": "ev_session"
    },
    "entities": {
      "user_context": "user_context",
      "core_action": "core_action",
      "application_context": "application_context"
    },
    "own_schema_events": ["app_background", "app_foreground"],
    "drop_events": ["app_start"],
    "business_kind": "click",
    "business_event_kinds": {},
    "web": { "endpoint": "", "appId": "" }
  },
  "tracing": {
    "enabled": false,
    "allowlist_hosts": []
  },
  "flavors": {
    "dev": {
      "sdk_config": { "logLevel": "debug", "verboseLogging": true }
    },
    "staging": {
      "snowplow": { "endpoint": "https://collector-staging.example.com" }
    }
  }
}
```

Ba giá trị bắt buộc phải sửa: `snowplow.endpoint`, `snowplow.appId`, và
`pii_salt`. Phần còn lại dùng được nguyên trạng.

`snowplow.web` cho phép ghi đè riêng cho nền web khi cùng một file cấu hình
được dùng chung với mobile. Để rỗng thì SDK lấy giá trị ở cấp trên.

`flavors` là các khối ghi đè theo môi trường, chọn lúc khởi tạo. Khối `dev` ở
trên chỉ bật log, khối `staging` đổi collector — mọi khoá khác giữ nguyên từ
cấu hình gốc.

---

## 3. Khởi tạo

```js
const READY = UniTrack.initializeFromConfig('/unitrack.config.json');
```

Hàm này trả về Promise. Nếu ứng dụng bắn event ngay lúc khởi động thì phải chờ
Promise resolve, nếu không event đầu tiên rơi vào lúc SDK chưa sẵn sàng và bị
bỏ:

```js
READY.then(() => {
  render();
});
```

Chọn flavor bằng tham số thứ hai:

```js
const flavor = location.hostname === 'localhost' ? 'dev' : 'staging';
UniTrack.initializeFromConfig('/unitrack.config.json', flavor);
```

---

## 4. Gắn tracking vào code

SDK gộp mọi event vào bảy nhóm, mỗi nhóm ứng với một schema. Chọn hàm theo bản
chất hành vi, ngay tại chỗ gắn tracking:

| Hàm | Schema | Dùng khi |
|---|---|---|
| `trackClick(action, data?)` | `ev_click` | người dùng bấm, chọn, mở |
| `trackResult(action, status, data?)` | `ev_result` | một thao tác hoàn tất, có kết quả |
| `trackApi(url, method, status, durationMs, data?)` | `ev_api` | gọi API |
| `trackCrash(message, data?)` | `ev_crash` | lỗi, ngoại lệ |

```js
// Hành vi bấm
UniTrack.trackClick('product_viewed', { product_id: 'SP-01' });

// Kết quả có outcome — đội dữ liệu đo tỉ lệ thành công trên nhóm này
UniTrack.trackResult('add_to_cart', 'success', { product_id: 'SP-01', price: 250000 });
UniTrack.trackResult('purchase', 'success', { order_id: 'DH-1', total: 250000 });
UniTrack.trackResult('form_submitted', 'error', { form_id: 'dang_ky', reason: 'email_trung' });

// Gọi API
UniTrack.trackApi('https://api.shop.vn/v1/cart', 'POST', 200, 143);

// Lỗi
UniTrack.trackCrash('Không tải được giỏ hàng', { fatal: false });
```

Tên bạn truyền vào (`add_to_cart`, `product_viewed`) đi lên trong field
`event_action`. Schema là nhóm; `event_action` là hành vi cụ thể. Đội dữ liệu
lọc theo `event_action`.

`trackResult` tự gắn thêm `action` và `status` vào payload.

### Trường hợp không sửa được chỗ gọi

Khi event bắn ra từ thư viện bên thứ ba, hoặc bạn muốn đổi phân loại mà không
build lại ứng dụng, khai trong `business_event_kinds`:

```json
"business_event_kinds": {
  "add_to_cart": "result",
  "purchase": "result",
  "product_share": "result"
}
```

Đây là lối thoát, không phải cách dùng chính. Ưu tiên gọi đúng hàm.

### Event có schema riêng

Nếu đội dữ liệu đã publish schema mang chính tên event lên Iglu registry, khai
trong `own_schema_events`:

```json
"own_schema_events": ["app_background", "app_foreground"]
```

Event nằm trong danh sách này giữ nguyên tên làm schema. Event **không** nằm
trong danh sách và không thuộc bảy nhóm sẽ đi theo `business_kind` — SDK không
bao giờ tự sinh schema từ tên event, vì schema chưa publish sẽ khiến collector
trả `ResolutionError` và toàn bộ event thành bad row.

### Chặn event

```json
"drop_events": ["app_start", "debug_ping"]
```

Event trong danh sách này không được gửi đi.

---

## 5. Event SDK tự bắt

Bật bằng `sdk_config.autoCapture` (mặc định `true`). Từng nhóm tắt được riêng:

| Event | Schema | Cờ điều khiển |
|---|---|---|
| `screen_viewed` | `screen_view` | `trackScreens` |
| `screen_exited` | `screen_end` | `trackScreens` |
| `click` | `ev_click` | `trackTaps` |
| `network_request` | `ev_api` | `trackNetwork` |
| `crash` | `ev_crash` | luôn bật |
| `app_start`, `app_foreground`, `app_background` | tuỳ cấu hình | `trackLifecycle` |
| `session_started`, `session_ended` | `ev_session` | luôn bật |

`screen_exited` mang `dwell_ms`, `foreground_sec`, `background_sec`,
`is_exit_screen` và `reason` (`screen_change`, `app_backgrounded`, `page_hide`).
`screen_viewed` mang `load_ms` và `previous_screen_name`.

### Đặt tên màn hình

Mặc định SDK lấy đường dẫn URL làm tên màn. Ứng dụng SPA nên tự đặt tên gọn hơn:

```js
function render() {
  const route = (location.hash || '#/').slice(1);
  UniTrack.setScreen(route);   // '/san-pham' thay vì '/index.html#/san-pham'
}
```

Gọi `setScreen()` ở mỗi lần đổi route. SDK tự đóng màn cũ (`screen_exited`) rồi
mở màn mới (`screen_viewed`) trong cùng một lời gọi.

### Auto-capture click

Nút cần bắt tự động thì gắn `data-track-id`:

```html
<button data-track-id="btn_them_gio">Thêm vào giỏ</button>
```

Giá trị này đi lên trong `element_key`.

---

## 6. Định danh người dùng

```js
await UniTrack.identify('user@example.com', {
  user_name: 'Nguyễn An',
  tier: 'gold',
});
```

`identify()` là hàm async. SDK băm SHA-256 kèm `pii_salt` cho `user_id`,
`user_name`, `phone_number` và `email` trước khi gửi — collector không bao giờ
nhận giá trị gốc. Các trait khác (`tier`) giữ nguyên.

Đăng xuất:

```js
UniTrack.reset();
```

`reset()` xoá định danh và xoay `session_id`. Gọi `track` cho event `logout`
**trước** `reset()`, nếu không event đó rơi vào session mới.

Trước khi `identify()`, entity `user_context` vẫn được gửi nhưng `user_id` và
`user_name` là chuỗi rỗng. Cấu trúc hàng dữ liệu vì thế đồng nhất giữa khách
vãng lai và người đã đăng nhập.

Đọc trạng thái hiện tại:

```js
UniTrack.currentUser();   // { userId: '<hash>', traits: {...} }
```

---

## 7. Session

SDK tự quản `session_id`, lưu trong `localStorage` để giữ liền mạch giữa các
tab và sau khi tải lại trang.

Session xoay khi: quá `sessionTimeoutMs` không có hoạt động (mặc định 30 phút),
gọi `reset()`, hoặc gọi `rotateSession()`.

Mỗi lần xoay sinh hai event: `session_ended` mang thông tin phiên vừa đóng
(`session_duration_sec`, `screen_count`, `had_error`, `had_crash`, `reason`), và
`session_started` mang `previous_session_id` nối sang phiên trước.

`session_ended` mang `session_id` của phiên **vừa đóng**, không phải phiên mới.

```js
UniTrack.currentSessionId();    // id phiên hiện tại
UniTrack.sessionIndex();        // phiên thứ mấy
UniTrack.previousSessionId();   // id phiên trước
UniTrack.rotateSession();       // xoay thủ công
```

---

## 8. Consent và quyền riêng tư

Bật `require_consent` thì SDK im lặng cho tới khi người dùng đồng ý:

```json
"sdk_config": { "require_consent": true }
```

```js
UniTrack.setConsent(true);    // người dùng đồng ý
UniTrack.setConsent(false);   // từ chối — SDK ngừng thu thập
UniTrack.hasConsent();
```

Khi `require_consent` bật mà chưa có đồng ý, event bị chặn ngay tại `track()`:
không vào buffer, không lưu xuống IndexedDB.

`sampling_rate` giảm lượng dữ liệu thu thập. Quyết định lấy hay bỏ là tất định
theo `session_id`, nên một phiên đã được chọn thì mọi event của phiên đó đều
được lấy — không phải random từng event.

```json
"sdk_config": { "sampling_rate": 0.1 }
```

---

## 9. Plugin tuỳ chọn

Ngoài event mặc định, SDK có các plugin bật riêng:

```js
import UniTrack, {
  webVitalsPlugin, formTrackingPlugin, engagementPlugin,
  mediaPlugin, streamingPlugin, crossDomainPlugin,
} from 'unitrack-web';

UniTrack.use(webVitalsPlugin());
UniTrack.use(engagementPlugin({ scrollMilestones: [25, 50, 75, 100] }));
UniTrack.use(formTrackingPlugin());
```

| Plugin | Event sinh ra |
|---|---|
| `webVitalsPlugin` | LCP, CLS, INP, TTFB |
| `engagementPlugin` | `scroll_depth`, `rage_click`, `dead_click` |
| `formTrackingPlugin` | `form_field_focus`, `form_field_blur`, `form_submit` |
| `mediaPlugin` | `media_play`, `media_pause`, `media_progress`, `media_ended` |
| `streamingPlugin` | `stream_first_frame`, `stream_stalled`, `stream_stats` |
| `crossDomainPlugin` | `cross_domain_link` — xem [mục 10](#10-cross-domain) |

Plugin sinh event có tên riêng, không thuộc bảy nhóm chuẩn. Khai chúng trong
`business_event_kinds` hoặc `own_schema_events` trước khi bật, nếu không chúng
đi theo `business_kind` mặc định.

---

## 10. Cross-domain

`localStorage` bị cô lập theo origin. Người dùng đi từ `shop.vn` sang
`thanhtoan.vn` là mất session — một hành trình mua hàng bị cắt thành hai người
dùng khác nhau trong báo cáo.

Plugin `crossDomainPlugin` giải quyết bằng cách gắn tham số `_sp` vào link ra
ngoài, trang đích đọc lại và nối tiếp session cũ.

### Trang nguồn

```js
import UniTrack, { crossDomainPlugin } from 'unitrack-web';

UniTrack.use(crossDomainPlugin({
  // BẮT BUỘC. Chỉ trang trí link bạn kiểm soát.
  shouldDecorate: (link) => link.hostname.endsWith('.congty.vn'),
  getSessionId: () => UniTrack.currentSessionId(),
  getUserId: () => UniTrack.currentUser().userId || null,
  sourceId: 'shop',
}));
```

| Tuỳ chọn | Bắt buộc | Ý nghĩa |
|---|---|---|
| `shouldDecorate` | có | Trả `true` nếu link được phép mang session sang |
| `getSessionId` | có | Hàm trả session hiện tại |
| `getUserId` | không | ID người dùng đã băm |
| `sourceId` | không | Tên nguồn, mặc định lấy hostname |

`shouldDecorate` **không có mặc định**, và đó là chủ ý. Trang trí mọi link ra
ngoài đồng nghĩa với việc gửi `session_id` sang mạng quảng cáo, CDN và bất kỳ
tên miền nào người dùng bấm vào. Chỉ khai những tên miền bạn sở hữu.

`sourceId` không được chứa dấu chấm — đó là ký tự phân tách của định dạng. Khi
bạn để trống, SDK lấy hostname và tự đổi dấu chấm thành gạch ngang
(`shop.vn` → `shop-vn`).

### Trang đích

Không cần code. SDK tự đọc `_sp` lúc khởi tạo và nối session:

```js
await UniTrack.initializeFromConfig('/unitrack.config.json');
// session_id đã là của trang nguồn
```

Tắt hành vi này khi cần:

```json
"sdk_config": { "crossDomainSession": false }
```

Muốn đọc thông tin nguồn để xử lý riêng:

```js
import { readCrossDomainSession } from 'unitrack-web';

const inbound = readCrossDomainSession();
// { sessionId, userId, sourceId, ageMs } hoặc null
```

### Cách hoạt động

Link được trang trí **lúc bấm**, không phải lúc tải trang — vì `href` có thể
đổi, link có thể được thêm vào sau, và `session_id` phải là giá trị tại thời
điểm rời đi. SDK bắt cả `click`, `auxclick` (chuột giữa mở tab mới) và
`contextmenu` (sao chép địa chỉ link).

Link sau khi trang trí:

```
https://thanhtoan.vn/gio-hang?_sp=<session>.<timestamp>.<session>.<user>.shop.web
```

Định dạng này giống Snowplow chuẩn, nên đường dữ liệu nào đang parse `_sp` sẵn
vẫn hiểu được.

Mỗi lần trang trí sinh event `cross_domain_link` mang `target_host`.

### Giới hạn 5 phút

Tham số `_sp` hết hạn sau 5 phút. Người dùng có thể sao chép URL đã trang trí
rồi gửi cho người khác qua chat; không có giới hạn thời gian thì người nhận sẽ
thừa hưởng nhầm session của người gửi.

Vì thế cross-domain chỉ dùng được cho luồng điều hướng trực tiếp. Link dán vào
email hay tin nhắn sẽ hết hạn trước khi người nhận bấm vào — đó là hành vi
đúng, không phải lỗi.

### Điều cần biết trước khi bật

`adopt()` **không tăng** `session_index`. Người dùng vẫn đang trong cùng một
phiên, chỉ là đi qua ranh giới tên miền.

Hai tên miền phải dùng chung `iglu_vendor` và `appId` nếu bạn muốn báo cáo nối
liền hai bên. Khác `appId` thì dữ liệu vẫn về cùng collector nhưng nằm ở hai
ứng dụng khác nhau.

Cross-domain không thay thế cookie bên thứ ba cho mục đích quảng cáo. Nó chỉ
nối session phân tích trong phạm vi các tên miền bạn sở hữu.

---

## 11. Tham chiếu cấu hình

### `sdk_config`

| Khoá | Mặc định | Ý nghĩa |
|---|---|---|
| `autoCapture` | `true` | Bật toàn bộ auto-capture |
| `trackScreens` | `true` | Event màn hình |
| `trackTaps` | `true` | Event click |
| `trackNetwork` | `true` | Event gọi API |
| `trackLifecycle` | `true` | Event vòng đời trang |
| `batchSize` | `10` | Số event mỗi lần gửi |
| `flushIntervalMs` | `3000` | Chu kỳ gửi (ms) |
| `sessionTimeoutMs` | `1800000` | Thời gian idle trước khi xoay session |
| `crossDomainSession` | `true` | Nhận session từ tên miền khác qua `_sp` |
| `sampling_rate` | `1.0` | Tỉ lệ lấy mẫu, `0`–`1` |
| `require_consent` | `false` | Chờ đồng ý mới thu thập |
| `screen_start_event` | `screen_viewed` | Tên event vào màn |
| `screen_end_event` | `screen_exited` | Tên event rời màn |
| `logLevel` | `warn` | `debug` bật log chi tiết |
| `verboseLogging` | `false` | Bật log chi tiết trực tiếp |

### `snowplow`

| Khoá | Bắt buộc | Ý nghĩa |
|---|---|---|
| `enabled` | có | Bật gửi lên collector |
| `endpoint` | có | URL collector |
| `appId` | có | Mã ứng dụng, đi trong field `aid` |
| `iglu_vendor` | có | Vendor của schema |
| `default_version` | không | Mặc định `1-0-0` |
| `event_names` | không | Map nhóm sang tên schema |
| `entities` | không | Entity gắn vào mọi event |
| `own_schema_events` | không | Event dùng chính tên nó làm schema |
| `drop_events` | không | Event không gửi đi |
| `business_kind` | không | Nhóm mặc định, mặc định `click` |
| `business_event_kinds` | không | Nhóm riêng cho từng event |
| `web` | không | Ghi đè `endpoint`/`appId` cho web |

### `tracing`

Chèn header `traceparent` (W3C Trace Context) vào request gửi tới các host
trong danh sách, để nối log frontend với backend:

```json
"tracing": {
  "enabled": true,
  "allowlist_hosts": ["api.shop.vn", "*.shop.vn"]
}
```

Backend phải trả `Access-Control-Allow-Headers: traceparent`, nếu không
preflight thất bại và request không gửi được.

---

## 12. Payload gửi đi

Mỗi event là một self-describing event theo giao thức Snowplow tp2:

```json
{
  "schema": "iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-4",
  "data": [{
    "e": "ue",
    "eid": "1f2e3d4c-...",
    "aid": "ma_app_cua_ban",
    "p": "web",
    "url": "https://shop.vn/san-pham",
    "ue_pr": "{...}",
    "co": "{...}"
  }]
}
```

`ue_pr` sau khi giải mã:

```json
{
  "schema": "iglu:com.snowplowanalytics.snowplow/unstruct_event/jsonschema/1-0-0",
  "data": {
    "schema": "iglu:vn.fpt.ftel.snowplow/ev_result/jsonschema/1-0-0",
    "data": {
      "event_action": "add_to_cart",
      "action": "add_to_cart",
      "status": "success",
      "product_id": "SP-01",
      "session_id": "...",
      "screen": "/san-pham"
    }
  }
}
```

`co` chứa ba entity gắn vào mọi event:

| Entity | Nội dung |
|---|---|
| `user_context` | `user_id`, `user_name`, `phone_number` — đã băm, rỗng khi chưa đăng nhập |
| `core_action` | `action_name`, `timestamp`, `start_time`, `session_id`, `screen`, `element_key`, `is_headless` |
| `application_context` | `app_id`, `platform`, `user_agent`, `screen_resolution`, `viewport`, `language`, `referrer` |

Mọi giá trị trong entity là chuỗi, khớp với schema Iglu.

---

## 13. Debug

Bật log chi tiết:

```json
"sdk_config": { "verboseLogging": true }
```

Console hiện từng event kèm schema, entity đã giải mã, và payload gốc:

```
▸ [UniTrack→Snowplow] add_to_cart → ev_result
    schema  : iglu:vn.fpt.ftel.snowplow/ev_result/jsonschema/1-0-0
    event   : { event_action: "add_to_cart", status: "success", ... }
    entities: [ user_context, core_action, application_context ]
    payload : { e: "ue", eid: ..., ue_pr: "...", co: "..." }
```

Và mỗi lần gửi:

```
[UniTrack→Snowplow] POST 5 event
```

Tắt `verboseLogging` trước khi lên production.

Gửi ngay không đợi hết chu kỳ:

```js
await UniTrack.flush();
```

---

## 14. Lỗi thường gặp

**Event không lên collector.** Kiểm tra `snowplow.enabled` là `true` và
`snowplow.endpoint` đúng. Mở tab Network, lọc theo host collector. Nếu không có
request nào, bật `verboseLogging` xem SDK có nhận event không.

**Preflight CORS thất bại.** Collector phải trả
`Access-Control-Allow-Origin` cho tên miền của trang, và
`Access-Control-Allow-Headers: Content-Type`.

**Event thành bad row với `ResolutionError`.** Schema chưa được publish lên
Iglu registry. Đối chiếu danh sách schema SDK dùng (`ev_click`, `ev_result`,
`ev_api`, `ev_crash`, `ev_session`, `screen_view`, `screen_end`, cộng những
tên trong `own_schema_events`) với schema đã có trên registry.

**Mỗi lần đổi màn sinh hai cặp event.** Ứng dụng gọi `setScreen()` nhưng để
tên khác với đường dẫn URL. SDK xử lý được trường hợp này; nếu vẫn thấy trùng,
kiểm tra `setScreen()` có được gọi ở **mọi** lần đổi route không.

**`user_context` rỗng sau khi đăng nhập.** `identify()` là hàm async — phải
`await` trước khi bắn event tiếp theo.

**Event mất khi mất mạng.** Không mất. SDK lưu xuống IndexedDB và gửi lại khi
có mạng. Kiểm tra số event đang chờ:

```js
await UniTrack.pendingEventCount();
```

**Không thấy event nào dù đã gọi `track()`.** Kiểm tra `require_consent` — nếu
bật mà chưa gọi `setConsent(true)` thì SDK chặn toàn bộ. Kiểm tra tiếp
`sampling_rate`.
