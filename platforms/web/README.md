# unitrack-web

SDK analytics cho web — auto-capture screen / tap / network / crash / lifecycle,
offline queue bền qua reload, W3C trace context, fan-out sang Snowplow, GA4,
Mixpanel, Amplitude, Segment hoặc bất kỳ hệ nào khác.

API parity với bản Flutter / iOS / Android.

## Cài đặt

```bash
npm install unitrack-web
```

Rồi khởi tạo bằng file config JSON:

```bash
# Copy file mẫu ra thư mục tĩnh, sửa apiKey + endpoint
cp node_modules/unitrack-web/unitrack.config.example.json public/unitrack.config.json
```

```js
import UniTrack from 'unitrack-web';

await UniTrack.initializeFromConfig('/unitrack.config.json');
```

Không dùng bundler thì nhúng thẳng file IIFE:

```html
<script src="node_modules/unitrack-web/dist/unitrack.iife.js"></script>
<script>UniTrack.initializeFromConfig('/unitrack.config.json');</script>
```

Hướng dẫn đầy đủ: https://mobix.asia/event-tracking-mobile/web-sdk-integration-guide.html

## Cài đặt

```sh
npm install unitrack-web
```

Hoặc thẻ script, không cần build:

```html
<script src="https://mobix.asia/event-tracking-mobile/unitrack-web-demo/dist/unitrack.iife.js"></script>
```

## Chạy được trong 3 bước

```ts
import UniTrack, { HttpProvider } from 'unitrack-web';

// 1. Khởi tạo — một lần, càng sớm càng tốt
UniTrack.initialize('utk_khoa_cua_ban', {
  endpoint: 'https://mobix.asia/event-tracking-mobile/v1/events',
  autoCapture: true,
  trackScreens: true,
  trackTaps: true,
  trackNetwork: true,
  trackLifecycle: true,
  piiSalt: 'chuoi_salt_rieng',
});

// 2. Nơi gửi event
UniTrack.addProvider(new HttpProvider({
  endpoint: 'https://mobix.asia/event-tracking-mobile/v1/events',
  apiKey:   'utk_khoa_cua_ban',
  batchSize: 20,
  flushIntervalMs: 3000,
}));
```

```html
<!-- 3. Đánh dấu nút quan trọng -->
<button data-track-id="cam_fullscreen">Toàn màn hình</button>
```

> **`endpoint` khai hai lần là có chủ đích.** Ở `initialize` nó dùng để SDK tự
> loại host đó khỏi network capture — không có thì SDK track chính request của
> mình, thành vòng lặp. Ở `HttpProvider` mới là nơi thật sự gửi.

## Event tự bắn từ đây

| Event | Khi nào | Field đáng chú ý |
|---|---|---|
| `app_start` | Trang tải xong | `nav_type` (vào mới / F5 / back-forward), `start_ms` |
| `screen_viewed` | Đổi route | `screen`, `title` |
| `screen_load_completed` | Ngay sau đó | `load_ms` |
| `screen_exited` | Rời màn | `dwell_ms`, `reason` (`screen_change` / `app_background` / `page_hide`) |
| `click` | Bấm phần tử tương tác | `element_key`, `tag` |
| `network_request` / `network_error` | fetch/XHR xong | `status_code`, `duration_ms`, `url` (đã cắt query) |
| `app_background` / `app_foreground` | Ẩn/hiện tab | `background_sec` |
| `crash` | Lỗi runtime + promise rejection | `message`, `stack`, `type` |

Bấm vào **vùng trống** (nền `<section>`, `<nav>`, `<body>`) bị bỏ qua — không
sinh event rác.

## Plugin

Plugin nằm ngoài phần lõi, chỉ tải khi `import`. Trang không có video thì không
tải code media.

```ts
import {
  webVitalsPlugin, formTrackingPlugin, engagementPlugin,
  mediaPlugin, streamingPlugin, crossDomainPlugin,
} from 'unitrack-web';

UniTrack.use(webVitalsPlugin());     // LCP / CLS / INP / FCP / TTFB + xếp hạng
UniTrack.use(formTrackingPlugin());  // bỏ dở form ở ô nào
UniTrack.use(engagementPlugin());    // scroll depth, rage click, dead click
UniTrack.use(mediaPlugin());         // video/audio: play, seek, % xem
UniTrack.use(streamingPlugin());     // chất lượng luồng live (xem bên dưới)
```

| Plugin | Event |
|---|---|
| `webVitalsPlugin` | `web_vital` — `metric`, `value`, `rating` |
| `formTrackingPlugin` | `form_field_focus` / `form_field_blur` / `form_submit` |
| `engagementPlugin` | `scroll_depth`, `rage_click`, `dead_click` (mặc định tắt) |
| `mediaPlugin` | `media_play/pause/seek/ended/progress/error` |
| `streamingPlugin` | `stream_*` — xem mục riêng bên dưới |
| `crossDomainPlugin` | `cross_domain_link` + nối session qua domain |

**Form tracking không bao giờ ghi giá trị người dùng nhập** — chỉ có điền hay
không và độ dài. Field `password` / `cvv` / `card` / `otp`… bị bỏ qua hoàn toàn.

## Streaming — cho web camera / video trực tiếp

Khác `mediaPlugin` (đo hành vi người dùng), plugin này đo **chất lượng đường
truyền** — thứ quyết định người dùng có xem được hay không.

```ts
UniTrack.use(streamingPlugin({
  statsIntervalMs: 30000,   // nhịp lấy mẫu bitrate/khung rớt. 0 = tắt
  minStallMs: 500,          // khựng ngắn hơn thì bỏ qua, tránh nhiễu
  trackMjpeg: true,         // theo dõi cả <img> MJPEG (camera đời cũ)
  mjpegSelector: 'img[data-stream]',
}));
```

| Event | Ý nghĩa |
|---|---|
| `stream_connecting` | Bắt đầu kết nối |
| `stream_first_frame` | **Khung hình đầu hiện ra** — kèm `ttff_ms` |
| `stream_stalled` | Đang xem thì khựng — kèm `stall_ms` |
| `stream_resumed` | Chạy lại sau khi khựng |
| `stream_reconnecting` | WebRTC rớt, đang thử nối lại |
| `stream_failed` | Bỏ cuộc — kèm `error_code` |
| `stream_ended` | Kết thúc — kèm `watched_ms` |
| `stream_stats` | Mẫu định kỳ: `dropped_frames`, `buffer_ahead_sec`, `width`/`height` |

Nguồn tín hiệu:

| Công nghệ | Cách bắt |
|---|---|
| `<video>` (HLS, DASH, MP4) | `loadstart` / `loadeddata` / `waiting` / `playing` / `error` |
| WebRTC | Vá `RTCPeerConnection`, nghe `connectionstatechange` |
| MJPEG qua `<img>` | `load` / `error` (bật `trackMjpeg`) |

`stream_id` lấy từ `data-track-id` hoặc `id`, **không bao giờ lấy `src`** — URL
stream thường chứa token phiên hoặc IP camera nội bộ.

> WebRTC `disconnected` được báo là `stream_reconnecting`, không phải
> `stream_failed`: trạng thái này thường tự hồi, gộp vào lỗi sẽ thổi phồng tỉ lệ
> hỏng.

## Fan-out sang nơi khác

Bắt event một lần, gửi đi nhiều nơi. Không phải nhúng 4 SDK và gọi 4 lần cho
cùng một hành động.

```ts
import { SnowplowProvider, GA4Provider, SdkBridgeProvider } from 'unitrack-web';

// Snowplow
UniTrack.addProvider(new SnowplowProvider({
  endpoint: 'https://collector.cong-ty.vn',
  appId: 'web_camera',
  igluVendor: 'vn.congty.tracker',
}));

// Google Analytics 4 — trang tự nạp gtag, provider chỉ đẩy event vào
UniTrack.addProvider(new GA4Provider({
  eventNames: { click: 'select_content' },
}));

// Mixpanel / Amplitude / Segment / PostHog / Firebase / hệ nội bộ
UniTrack.addProvider(new SdkBridgeProvider({
  name: 'Mixpanel',
  track: (n, p) => mixpanel.track(n, p),
  identify: (id) => id && mixpanel.identify(id),
  filter: (n) => n !== 'network_request',   // chặn loại ồn khỏi bên tính tiền
}));
```

| Nơi nhận | Provider | Ghi chú |
|---|---|---|
| Portal UniTrack | `HttpProvider` | Đường mặc định |
| Snowplow | `SnowplowProvider` | Iglu schema, endpoint tp2 |
| Google Analytics 4 | `GA4Provider` | Tự làm sạch tên cho hợp luật GA4 |
| Mixpanel / Amplitude / Segment / PostHog / Firebase | `SdkBridgeProvider` | 3 dòng mỗi cái |
| Hệ nội bộ | `SdkBridgeProvider` | Hoặc `HttpProvider` trỏ endpoint riêng |

`filter` đáng dùng: Mixpanel và Amplitude tính tiền theo lượng event, mà
auto-capture sinh nhiều `network_request`.

### Tự viết provider

Interface chỉ có 4 hàm:

```ts
class ProviderCuaToi {
  name = 'CuaToi';
  init()              { /* tuỳ chọn — gọi 1 lần sau initialize */ }
  track(name, props)  { /* BẮT BUỘC */ }
  setUser(id, traits) { /* tuỳ chọn */ }
  setScreen(name)     { /* tuỳ chọn */ }
}
UniTrack.addProvider(new ProviderCuaToi());
```

## API dùng tay

| API | Dùng khi |
|---|---|
| `track(name, props)` | Sự kiện nghiệp vụ tự định nghĩa |
| `customTrack(name, {action, data, includeUser})` | Như trên, có stamp `event_action` |
| `identify(userId, traits)` | Sau đăng nhập — tự hash nếu có `piiSalt` |
| `reset()` | Đăng xuất — xoá danh tính **và xoay session** |
| `setScreen(name)` | Tự đặt tên màn (modal, tab trong trang) |
| `setConsent(true/false)` / `hasConsent()` | Người dùng trả lời banner cookie |
| `currentSessionId()` / `sessionIndex()` / `previousSessionId()` | Nối log frontend ↔ backend |
| `rotateSession()` | Ép mở phiên mới |
| `flush()` | Ép gửi ngay |
| `pendingEventCount()` | Số event còn nằm trong offline queue |

## Cấu hình

| Cờ | Mặc định | Ý nghĩa |
|---|---|---|
| `endpoint` | `''` | Dùng để loại host khỏi network capture |
| `autoCapture` | `true` | Công tắc tổng |
| `trackScreens` / `trackTaps` / `trackNetwork` / `trackLifecycle` | `true` | Bật từng loại |
| `sessionTimeoutMs` | 30 phút | Idle quá ngưỡng → phiên mới |
| `samplingRate` | `1` | 0.0–1.0. Quyết định một lần cho cả phiên; `crash` luôn gửi |
| `requireConsent` | `false` | `true` → im lặng tới khi `setConsent(true)` |
| `anonymousTracking` | tắt | `'session'` (bỏ định danh, giữ phiên) hoặc `'full'` (không ghi localStorage) |
| `crossDomainSession` | `true` | Đọc `_sp` trong URL để nối phiên |
| `piiSalt` | `''` | Hash SHA-256 user_id trước khi rời máy |
| `tracingAllowlistHosts` | `[]` | Host được inject `traceparent`. Rỗng = không inject |
| `screenStartEvent` / `screenEndEvent` / `screenLoadEvent` / `clickEvent` | tên chuẩn | Đổi tên event mà không sửa code |

## Offline queue

Event gửi hỏng được cất vào **IndexedDB**, không phải bộ nhớ — đóng tab hay
reload vẫn còn. Mở lại trang thì tự gửi tiếp, giữ nguyên `event_id` và
`timestamp` gốc nên không sinh bản trùng và mốc thời gian không nhảy.

- Trần 1000 event, vượt thì bỏ cái cũ nhất
- Retry giãn gấp đôi mỗi lần hỏng, trần 60 giây
- HTTP 5xx thì giữ lại; 4xx thì bỏ (gửi lại cũng hỏng, tránh kẹt queue)
- `sendBeacon` lúc đóng tab; thất bại thì cất xuống queue

## Ẩn danh

```ts
UniTrack.initialize('utk_...', { anonymousTracking: 'session' });
```

| Mức | Định danh | Session | localStorage |
|---|---|---|---|
| `'session'` | bỏ | giữ | có ghi |
| `'full'` | bỏ | mỗi lần tải trang là phiên mới | **không ghi gì** |

Chặn ở 3 tầng: `identify()` bỏ qua, `customTrack({includeUser})` vô hiệu, và
`track()` lọc `user_id` / `email` / `user_name` kể cả khi app tự nhét vào.

## Cấu hình gợi ý cho web camera

```ts
UniTrack.initialize('utk_...', {
  endpoint: '...',
  sessionTimeoutMs: 4 * 60 * 60 * 1000,   // 4 giờ: người xem camera để tab hàng giờ
  samplingRate: 1,                         // giảm nếu lượng thiết bị lớn
});
UniTrack.use(streamingPlugin({ trackMjpeg: true }));
```

Gắn `data-track-id` cho ô camera và nút điều khiển. Không gắn thì SDK rơi xuống
nhánh đọc chữ trên nút, và tên event sẽ thành “Camera phòng ngủ” — dữ liệu nói
lên bố cục nhà khách hàng.

## Self-check

Bộ kiểm chạy trên bundle thật, mở thẳng trong trình duyệt:

| Trang | Kiểm |
|---|---|
| `demo/click-gate-check.html` | Lọc click rác, Shadow DOM, `cursor:pointer` |
| `demo/queue-check.html` | Offline queue, trần, backoff |
| `demo/session-check.html` | `reset()` xoay phiên, tính duy nhất của `session_id` |
| `demo/dwell-consent-check.html` | `dwell_ms`, consent, sampling |
| `demo/plugins-check.html` | 4 plugin, rò rỉ giá trị form |
| `demo/streaming-check.html` | Vòng đời stream, TTFF, khựng |
| `demo/privacy-check.html` | Cross-domain, chống rò session |
| `demo/anon-check.html` | Hai mức ẩn danh |
| `demo/torture.html` | 21 tình huống web hiện đại hay làm vỡ tracking |

## Build

```sh
npm run build       # → dist/ (esm + cjs + iife)
npm run type-check
```

Bundle IIFE ~115KB (gộp tất cả). Bản ESM tree-shake được — đo bằng esbuild:

| Dùng gì | Kích thước |
|---|---|
| Chỉ lõi | 14.7 KB |
| Lõi + streaming | 17.6 KB (+2.9 KB) |
| Lõi + media | 16.0 KB (+1.3 KB) |

Plugin không `import` thì không vào bundle.
