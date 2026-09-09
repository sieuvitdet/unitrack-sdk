# UniTrack Web SDK — tổng kết tình trạng (cập nhật 2026-08-27)

Tài liệu ghi lại toàn bộ những gì đã làm với Web SDK trong đợt vừa rồi, các bug
đã sửa, và **hai vấn đề còn đang mở** chặn đường data. Viết cho người tiếp nhận
sau, nên phần nào chưa chắc chắn đều ghi rõ là chưa chắc chắn.

---

## 1. Tình trạng hiện tại

| Mục | Giá trị |
|---|---|
| Package npm | `unitrack-web` (không scope) |
| Bản mới nhất trên npm | **0.2.1** (đã publish: 0.1.0, 0.2.0, 0.2.1) |
| Branch | `debug/headless-session` |
| Source | `platforms/web/src/` |
| Demo | `platforms/web/demo/` — **nằm ngoài git** (xem mục 6) |
| Endpoint demo đang trỏ | `https://99cb-42-119-252-18.ngrok-free.app` → `ftracking-stag.fpt.net:80` |
| appId demo | `567` |

**Link demo:** https://mobix.asia/event-tracking-mobile/unitrack-web-demo/showcase.html

Phải có đuôi `.html`. Portal chạy Express phục vụ file tĩnh theo đúng tên file,
không tự thêm đuôi như nginx — gõ thiếu sẽ ra `Cannot GET /...`. Bản rút gọn kết
thúc bằng `/` cũng chạy được nhờ `index.html` trong thư mục.

---

## 2. Vấn đề đang mở — chặn data

### 2.1. Đội data không thấy data mới, dù HTTP trả 200

**Đây là vấn đề nghiêm trọng nhất, chưa giải quyết xong.**

Điều quan trọng cần hiểu: **HTTP 200 không có nghĩa là data được lưu.** Đã kiểm
chứng bằng cách gửi body rác hoàn toàn lên collector staging:

```
{"khong":"phai-snowplow"}      ->  HTTP 200  "ok"
{"hoan":"toan","rac":"..."}    ->  HTTP 200  "ok"
```

Snowplow collector thiết kế **nhận trước, validate sau**: nó đẩy vào queue rồi
trả 200 ngay, việc kiểm schema xảy ra ở bước **enrich** phía sau. Event sai
schema rơi vào *bad rows*, không bao giờ tới bảng data.

Nên mọi kết luận "chạy tốt" chỉ dựa trên 200 đều **không đủ căn cứ**.

Endpoint thì đã xác minh là collector Snowplow thật, không phải proxy giả:

| Kiểm tra | Kết quả |
|---|---|
| `/health` | `200 ok` |
| `/i` (pixel) | `200`, `content-type: image/gif`, 43 bytes — GIF thật |
| Đường dẫn bịa đặt | `404 Not found` |

Tức là event **có tới nơi**, nhưng chết ở khâu sau.

**Nghi phạm (chưa xác nhận — cần đội data đọc bad rows):**

Payload web SDK đang gửi lên:

```
field gửi lên : aid, co, dtm, e, eid, p, page, tna, tv, ue_pr, url
THIẾU         : stm, p_ver
tv            : "js-unitrack-0.1"
```

1. **Thiếu `stm`** (device sent time) — `platforms/web/src/providers/snowplow.ts`
   không hề có chữ `stm` (đã grep, 0 kết quả). Enrich dùng `stm` để tính lệch giờ
   thiết bị; thiếu nó nhiều pipeline loại event.
2. **`tv = "js-unitrack-0.1"`** (`snowplow.ts:88`) — tracker version tự chế.
   Snowplow thật dùng dạng `js-3.x.x`. Một số cấu hình enrich lọc theo `tv`.

Chưa khẳng định được cái nào giết event vì không đọc được bad rows.

**Cần hỏi đội data đúng 3 câu:**

1. Xem **bad rows** staging trong khoảng thời gian test, lọc `app_id = 567` —
   nếu event nằm đó sẽ có lý do loại cụ thể.
2. Schema `iglu:vn.fpt.ftel.snowplow/ev_api/jsonschema/1-0-0` **đã đăng ký trên
   Iglu staging chưa?** Chưa có là event chết chắc ở enrich.
3. **appId `567` đã khai báo chưa?** Nếu pipeline chỉ nhận `555` thì 567 bị loại
   sạch dù vẫn trả 200.

### 2.2. SDK không đọc HTTP status — mất event trong im lặng

`platforms/web/src/providers/snowplow.ts:126`:

```ts
await fetch(`${this.cfg.endpoint}/com.snowplowanalytics.snowplow/tp2`, {...});
} catch {
  this.buffer.unshift(...batch);   // chỉ retry khi lỗi mạng
}
```

`fetch` được `await` nhưng **response bị vứt đi** — không đọc `res.ok`, không
đọc `res.status`. Mà `fetch` chỉ `throw` khi lỗi mạng; HTTP 429/500 vẫn là
promise thành công.

| Tình huống | Thực tế | SDK hiểu là |
|---|---|---|
| 200 `ok` | Thành công | Thành công |
| **429 rate limit** | **Mất event** | **Thành công → xoá khỏi buffer** |
| 500 server lỗi | Mất event | Thành công → xoá khỏi buffer |
| Mất mạng | Thất bại | Thất bại → retry đúng |

Cross-origin còn tệ hơn: trang lỗi 429 của nginx không kèm header CORS nên
`fetch` bị `throw` → rơi vào `catch` → event `unshift` lại buffer và **retry vô
hạn** vào endpoint đang chặn.

`flushBeacon` về bản chất không đọc được status — `sendBeacon` chỉ trả
`true/false` nghĩa là "đã xếp hàng". Đây là giới hạn thật của trình duyệt.

**Hướng sửa** (chưa làm — người dùng quyết định để nguyên):

```ts
const res = await fetch(url, {...});
if (!res.ok) {
  if (res.status === 429 || res.status >= 500) this.buffer.unshift(...batch);
  this.onResult?.({ ok: false, status: res.status, count: batch.length });
  return;
}
this.onResult?.({ ok: true, status: res.status, count: batch.length });
```

Sửa này chạm SDK lõi → phải build lại và publish npm bản mới thì demo mới dùng
được (demo lấy từ unpkg).

---

## 3. Bug đã sửa

### 3.1. Sampling loại sạch event (nghiêm trọng nhất đã sửa)

Demo bắn ra **0 event**. SDK log `track: sampled out` cho mọi event.

Nguyên nhân: `toSDKConfig` trả về `samplingRate: undefined` một cách tường minh.
Trong spread `{...defaultCfg(), ...config}`, **`undefined` ghi đè giá trị mặc
định** `1`. Sau đó `undefined >= 1`, `undefined <= 0`, và `hashUnit(...) <
undefined` đều false → `sessionSampled = false`.

Ảnh hưởng mọi người dùng `initializeFromConfig` mà không khai `sampling_rate`.

Sửa bằng `prune()` (`remote-config.ts:128`) xoá key `undefined` trước khi
spread. Kiểm chứng: trước 0 event, sau 18 event.

### 3.2. Default export npm hỏng

`import UniTrack from 'unitrack-web'` trả về namespace,
`.initializeFromConfig` là `undefined`. Do rollup `exports: 'named'` bỏ default
export. Bản IIFE không dính vì có footer làm phẳng.

Chỉ phát hiện được khi **cài tarball đã đóng gói vào project sạch**, không phát
hiện được bằng cách build. Sửa bằng footer cho cjs trong `rollup.config.mjs`.

### 3.3. Toàn bộ field payload ép về String

Yêu cầu: `"session_index": 26` → `"session_index": "26"`.

Làm tại **một chỗ duy nhất** là `track()` (`src/index.ts:72`, hàm
`stringifyProps`), không rải rác từng call site. `identify()` cũng dùng lại hàm
này cho `traits`.

### 3.4. Viết trùng code đã có

Bản đầu tôi tạo `file-config.ts` với `applyFlavor`/`toUniTrackConfig` — nhưng
`remote-config.ts` **đã có sẵn** `applyFlavor` (deep merge), `toSDKConfig`,
`fetchRemoteConfig`, và đã dùng snake_case. Bundle sinh ra **hai** `applyFlavor`
(rollup đổi tên một cái thành `applyFlavor$1`), chạy thì lỗi
`deepMerge is not defined`.

Đã xoá file thừa, chỉ thêm vào `remote-config.ts`: `apiKey`, `resolveSnowplow`
(dòng 93), và nhánh `snowplow.web`.

### 3.5. Schema sai so với file thật

Bản đầu viết camelCase, file iOS thật dùng **snake_case**, và `pii_salt` nằm ở
**root** chứ không trong `sdk_config`. Đã sửa theo đúng
`/Volumes/DucsM1/FPT-Life-FLI/FPTLife/FSDKTracking/trackingConfig.json`.

### 3.6. `session_id_salt` không tồn tại trên web

Tôi copy nhầm từ file iOS. iOS có 3 chỗ dùng, web **không có chỗ nào**. Đã bỏ
khỏi config và thêm bảng "khoá mobile có mà web chưa hỗ trợ" vào file hướng dẫn.

---

## 4. Cấu hình — cách hoạt động

Demo dùng **config tĩnh**, không lấy động từ api key:

```js
const READY = UniTrack.initializeFromConfig('unitrack.config.json');
```

File config theo đúng schema FPT Life. **Lưu ý quan trọng khi đổi endpoint:**
phải đổi **cả hai** chỗ, vì `resolveSnowplow` ưu tiên `web.endpoint`:

```js
endpoint: sp?.web?.endpoint || sp?.endpoint,
appId:    sp?.web?.appId    || sp?.appId,
```

Chỉ sửa mỗi `snowplow.endpoint` mà quên `snowplow.web.endpoint` thì SDK **vẫn
bắn về link cũ**.

---

## 5. Lệch giữa web và mobile

```
appId       : web 567          <->  mobile 555
event_names : web thiếu 'result' và 'screen_end'
entities    : xem giải thích bên dưới
```

Về `entities`: config web **không khai báo** khối `entities`, nhưng khác với
mobile, web **không đọc khối này từ config** — nó hardcode trong
`providers/snowplow.ts`. Nên việc thiếu khai báo trong config không có hậu quả
gì. Thực tế web gắn context như sau:

| Entity | Web | Ghi chú |
|---|---|---|
| `application_context` | **Luôn có** | `snowplow.ts:66` |
| `user_context` | **Chỉ khi đã `identify()`** | `snowplow.ts:60`, phụ thuộc `this.userId` |
| `core_action` | **Không có** | Web chưa cài đặt |

Nghĩa là trên demo, nếu chưa đăng nhập thì event **chỉ có
`application_context`**. Mobile có thêm `core_action`.

Ghi chú về mobile: file config trong repo iOS/Android là **cấu hình đang test**,
không phản ánh production. Production thật chạy `ftracking.fpt.vn` appId `555`
(theo xác nhận trực tiếp, không phải suy từ file).

---

## 6. Rủi ro còn tồn đọng

1. **`demo/` nằm ngoài git** — `platforms/web/demo/` bị gitignore vì repo
   `sieuvitdet/unitrack-sdk` là **public**, mà config demo từng chứa api key
   thật. Hệ quả: `showcase.html` và `unitrack.config.json` **không có version
   control, không có backup** ngoài các file `.bak-*` trên VPS.

2. **ngrok free đổi URL mỗi lần restart.** Tunnel chết thì event rơi hết mà
   **trang vẫn chạy bình thường, không báo lỗi** — dễ tưởng đang tracking tốt.
   Kiểm tra nhanh (phải gọi đúng path `tp2`, gọi root luôn trả 404 kể cả khi
   collector sống):

   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" -X POST \
     -H 'Content-Type: application/json' \
     -d '{"schema":"iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-4","data":[]}' \
     https://99cb-42-119-252-18.ngrok-free.app/com.snowplowanalytics.snowplow/tp2
   ```

3. **ngrok cold start nuốt event đầu tiên.** Request đầu sau khi tunnel nằm im
   một lúc bị `Failed to fetch`, từ request thứ hai trở đi mới 200. Vì SDK không
   đọc status (mục 2.2), event đầu **mất luôn không retry**. Khi demo cho người
   khác, bấm bừa một cái cho tunnel "ấm" trước rồi mới test thật.

4. **`ftracking.fpt.vn` chặn rate limit rất gắt.** Đã đo: request thứ 2 cách 2
   giây đã dính `429`, nghỉ 60 giây vẫn `429` — nginx chặn theo IP. Preflight
   `OPTIONS` trả CORS đúng, nhưng **trang lỗi 429 không kèm CORS header**, nên
   trên trình duyệt chỉ thấy `TypeError: Failed to fetch`, không lộ mã 429.
   Staging `99cb-...` thì bắn liên tục 6 phát đều 200, không bị chặn.

   Production chạy được vì hàng nghìn thiết bị, mỗi IP gửi rất thưa. Còn một
   người ngồi spam từ một IP thì dính ngay — cần xin whitelist IP văn phòng khi
   test.

---

## 7. Việc nên làm tiếp

1. **Nhờ đội data đọc bad rows** (mục 2.1) — quan trọng nhất, đang chặn toàn bộ
   đường data.
2. Tuỳ kết quả: thêm `stm` và sửa `tv`, hoặc đăng ký schema/appId phía Iglu.
3. Cân nhắc sửa mục 2.2 (đọc HTTP status) — nếu không, mọi lỗi phía server sẽ
   tiếp tục mất event trong im lặng và rất khó debug.
4. Bổ sung `entities` cho web để khớp mobile (mục 5).

---

## 8. Tài liệu liên quan

- `docs/web-sdk-integration-guide.html` — hướng dẫn tích hợp (npm-first)
- `docs/web-sdk-audit-2026-08.md`
- `docs/web-sdk-test-scenarios.md`
- `platforms/web/unitrack.config.example.json` — config mẫu, chỉ chứa placeholder
