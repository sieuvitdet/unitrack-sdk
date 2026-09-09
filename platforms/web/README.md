# unitrack-web

SDK thu thập hành vi người dùng trên web, gửi lên Snowplow collector. Toàn bộ
cấu hình nằm trong một file JSON.

## Cài đặt

```sh
npm install unitrack-web
```

Hoặc tự host file dựng sẵn:

```sh
npm pack unitrack-web
tar -xzf unitrack-web-*.tgz
cp package/dist/unitrack.iife.js public/js/
```

```html
<script src="/js/unitrack.iife.js"></script>
```

Ba file trong `dist`: `unitrack.iife.js` cho thẻ `<script>` (gắn biến toàn cục
`UniTrack`), `unitrack.esm.js` cho `import`, `unitrack.cjs.js` cho `require`.

## Cấu hình

Đặt `unitrack.config.json` ở thư mục public. Xem
[`unitrack.config.example.json`](./unitrack.config.example.json) để lấy bản đầy
đủ; bốn giá trị cần sửa:

```json
{
  "pii_salt": "chuoi_bi_mat_rieng_cua_ban",
  "snowplow": {
    "enabled": true,
    "endpoint": "https://collector.congty.vn",
    "appId": "ma_app_cua_ban"
  }
}
```

## Khởi tạo

```js
const READY = UniTrack.initializeFromConfig('/unitrack.config.json');

// Chờ xong mới render, nếu không event đầu tiên bị bỏ
READY.then(() => render());
```

Chọn flavor theo môi trường bằng tham số thứ hai:

```js
UniTrack.initializeFromConfig('/unitrack.config.json', 'staging');
```

## Bắn event

Bốn hàm, chọn theo bản chất hành vi:

```js
// Người dùng bấm, chọn, mở
UniTrack.trackClick('product_viewed', { product_id: 'SP-01' });

// Thao tác hoàn tất, có kết quả
UniTrack.trackResult('add_to_cart', 'success', { price: 250000 });
UniTrack.trackResult('purchase', 'error', { reason: 'the_bi_tu_choi' });

// Gọi API thủ công (SDK đã tự bắt fetch và XHR)
UniTrack.trackApi('https://api.congty.vn/v1/cart', 'POST', 200, 143);

// Lỗi tự bắt được
UniTrack.trackCrash('Không tải được giỏ hàng');
```

Tên truyền vào đi lên trong field `event_action`, không cần khai báo trước.

| Hàm | Schema |
|---|---|
| `trackClick` | `ev_click` |
| `trackResult` | `ev_result` |
| `trackApi` | `ev_api` |
| `trackCrash` | `ev_crash` |

## Event tự bắt

Chín event dưới đây không cần gọi hàm:

`screen_viewed` · `screen_exited` · `click` · `network_request` · `crash` ·
`app_start` · `app_background` · `app_foreground` · `session_started` ·
`session_ended`

Bắt click tự động bằng thuộc tính:

```html
<button data-track-id="btn_them_gio">Thêm vào giỏ</button>
```

## Tên màn hình

Ứng dụng SPA gọi `setScreen()` ở mỗi lần đổi route để có tên gọn hơn đường dẫn
URL:

```js
UniTrack.setScreen('/san-pham');
```

SDK tự đóng màn cũ và mở màn mới trong cùng lời gọi.

## Đăng nhập

```js
await UniTrack.identify('user@example.com', {
  user_name: 'Nguyễn An',
  tier: 'gold',
});

// Đăng xuất — bắn event trước, reset sau
UniTrack.trackClick('logout');
UniTrack.reset();
```

`identify()` băm SHA-256 kèm `pii_salt` cho email, tên và số điện thoại trước
khi gửi. `reset()` xoá định danh và xoay session.

## Consent

```json
{ "sdk_config": { "require_consent": true } }
```

```js
UniTrack.setConsent(true);
```

Khi bật mà chưa có đồng ý, event bị chặn ngay tại `track()` — không vào buffer,
không lưu xuống IndexedDB.

## Plugin

```js
import UniTrack, { webVitalsPlugin, engagementPlugin } from 'unitrack-web';

UniTrack.use(webVitalsPlugin());
UniTrack.use(engagementPlugin());
```

| Plugin | Event |
|---|---|
| `webVitalsPlugin` | LCP, CLS, INP, TTFB |
| `engagementPlugin` | `scroll_depth`, `rage_click`, `dead_click` |
| `formTrackingPlugin` | `form_field_focus`, `form_field_blur`, `form_submit` |
| `mediaPlugin` | `media_play`, `media_pause`, `media_progress`, `media_ended` |
| `streamingPlugin` | `stream_first_frame`, `stream_stalled`, `stream_stats` |
| `crossDomainPlugin` | `cross_domain_link` — giữ session qua nhiều tên miền |

Plugin sinh event tên riêng, không thuộc bảy nhóm chuẩn. Khai chúng trong
`business_event_kinds` hoặc `own_schema_events` trước khi bật.

## Debug

```json
{ "sdk_config": { "verboseLogging": true } }
```

Console hiện từng event kèm schema, entity và payload. Tắt trước khi lên
production.

## API

| Hàm | Mô tả |
|---|---|
| `initializeFromConfig(url, flavor?)` | Khởi tạo từ file config |
| `trackClick(action, data?)` | Event hành vi bấm |
| `trackResult(action, status, data?)` | Event có kết quả |
| `trackApi(url, method, status, ms, data?)` | Event gọi API |
| `trackCrash(message, data?)` | Event lỗi |
| `track(name, props?)` | Event thô, tự chọn nhóm |
| `setScreen(name)` | Đặt tên màn hình |
| `identify(userId, traits?)` | Định danh, async |
| `reset()` | Đăng xuất, xoay session |
| `setConsent(granted)` | Bật/tắt thu thập |
| `currentSessionId()` | Id phiên hiện tại |
| `flush()` | Gửi ngay, không đợi chu kỳ |

## Giấy phép

MIT
