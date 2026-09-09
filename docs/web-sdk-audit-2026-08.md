# Audit — UniTrack Web SDK vs Snowplow Browser Tracker

**Ngày:** 19/08/2026 · **Phạm vi:** toàn bộ `platforms/web/src` (~1300 LOC, 11 file)
**Đối chiếu:** Snowplow Browser Tracker (docs chính thức, tra qua context7)

Mọi kết luận dưới đây đều **đo bằng thực nghiệm trên production** hoặc trace trực
tiếp trong source, không suy đoán.

---

## Tóm tắt

Auto-capture của UniTrack web **mạnh hơn** Snowplow ở phần lõi: Snowplow cần bật
từng plugin rời, UniTrack bắt sẵn screen/tap/network/crash/lifecycle chỉ với một
lần `initialize()`.

Nhưng có **một lỗi nghiêm trọng làm mất dữ liệu**: offline queue **chưa từng được
đấu dây**. Đây là thứ phải sửa trước khi đưa vào production.

| Mức | Số vấn đề | Trạng thái |
|---|---|---|
| 🔴 Nghiêm trọng (mất dữ liệu) | 2 | ✅ đã sửa 19/08 |
| 🟠 Trung bình | 4 | ✅ đã sửa hết (P3, P4, P5, P6) |
| 🟡 Thiếu so với Snowplow | 6 | ✅ đã bù hết bằng plugin tự viết |

**Toàn bộ audit đã đóng (19/08).** Thêm cơ chế `CapturePlugin` (plugin đầu vào,
khác `AnalyticsProvider` là đầu ra) và 6 plugin: Web Vitals, form tracking,
engagement (scroll/rage/dead click), media, cross-domain, **streaming**. Cùng
với anonymous tracking 2 mức ('session' / 'full') ngay trong lõi.

Thêm 2 provider (20/08): `GA4Provider` và `SdkBridgeProvider` — cái sau nối
được Mixpanel / Amplitude / Segment / PostHog / Firebase / hệ nội bộ bằng 3
dòng, thay vì viết 5 provider gần giống nhau.

Bundle IIFE 65KB → 115KB, nhưng bản ESM tree-shake được: app chỉ dùng lõi là
14.7KB, thêm streaming +2.9KB, thêm media +1.3KB (đo bằng esbuild).

**8 bộ self-check, tất cả PASS trên production:** click-gate 17, queue 6,
session 6, dwell-consent 10, plugins 12, privacy 7, anon 6×2 chế độ,
streaming 14.

## Hai bug bắt được sau khi audit đóng

**Shadow DOM (19/08).** Click trong web component không được ghi nhận —
`event.target` bị retarget thành host. Sửa bằng `composedPath()[0]` + cho vòng
tìm tổ tiên leo qua `ShadowRoot.host`.

**Đồng hồ hệ thống nhảy (19/08).** `touch()` đo thời gian nhàn rỗi bằng
`Date.now()`; đồng hồ tiến 2 tiếng (NTP đồng bộ, máy thức sau khi ngủ) → tưởng
idle quá 30 phút → rotate. Đo thật: `session_index` chạy từ 3 lên 12 trong 4
giây. Sửa bằng `performance.now()` — đồng hồ đơn điệu.

Rủi ro cao với web camera vì tablet gắn tường / kiosk hay chỉnh giờ sau khi mất
điện.

**Đã sửa 19/08:** P1 (offline queue), P2 (trần + backoff), P4 (`load_ms` lần đầu).
Kèm 3 lỗi phát hiện thêm khi sửa: `flush()` không kiểm `res.ok` (HTTP 500 coi là
thành công), `navigator.onLine === false` giữ event trong RAM, `sendBeacon` trả
`false` thì mất trắng.

Self-check: `queue-check.html` 6/6 PASS, `click-gate-check.html` 15/15 PASS.
Đo thật trên session `d78ef976`: 50 reload liên tiếp, **0 event mất**,
214/214 `event_id` duy nhất, độ trễ trung vị 0.3s.

---

## 🔴 P1 — Offline queue là code chết, event mất khi đóng tab

**Bằng chứng (trace):** `Queue.enqueue()` không được gọi ở bất kỳ đâu ngoài chính
`offline-queue.ts`. `index.ts` chỉ gọi `drain()` / `removeIds()` / `pendingCount()`
— tức chỉ có phần **đọc**, không có phần **ghi**.

**Bằng chứng (đo thật trên production):**

```js
// chặn fetch tới ingest → bắn 3 event
UniTrack.track('probe_offline_1'); …
await UniTrack.pendingEventCount()   // → 0     (đáng lẽ phải là 3)
indexedDB.databases()                // → ['unitrack']  (DB có, nhưng rỗng)
```

Bắn tiếp **500 event** rồi reload: `pendingEventCount` vẫn `0`. Mất sạch.

**Cơ chế thật:** khi POST fail, `HttpProvider.flush()` chỉ `buffer.unshift(...batch)`
— đẩy ngược vào mảng **trong RAM**. Đóng tab / reload / crash → mất hết.

Header của file còn ghi *"Provider POST fail → retain event; reload page hoặc
reconnect online → tự flush"* — mô tả một hành vi chưa từng tồn tại.

**Snowplow:** mặc định `useLocalStorage: true`, `maxLocalStorageQueueSize: 1000`.
Docs cảnh báo thẳng rằng tắt nó là *"risky"* vì mất dữ liệu khi đóng trang. Ta
đang chạy đúng ở trạng thái rủi ro đó, mà không hề chọn.

**Sửa:** trong `catch` của `flush()` gọi `Queue.enqueue()`; `init()` gọi
`flushOfflineQueue()` lúc khởi động (hiện chỉ chạy khi có sự kiện `online`).

---

## 🔴 P2 — Buffer RAM không có trần

`HttpProvider.buffer` là mảng không giới hạn. Mất mạng kéo dài, hoặc endpoint
chết, thì nó phình vô hạn.

Đã đo: bắn 500 event khi ingest fail, không có cơ chế nào chặn. Native core có
trần 10.000 event + giữ 7 ngày; web không có gì.

Đi kèm: **retry không backoff**. Fail thì cứ 2 giây thử lại, mãi mãi. Endpoint sập
→ mỗi client tự biến thành máy phát request. Snowplow có exponential backoff.

**Sửa:** cắt buffer ở ~1000 (bỏ event cũ nhất, như `maxLocalStorageQueueSize`), và
giãn dần khoảng cách retry khi liên tiếp fail.

---

## 🟠 P3 — `screen_exited` khai báo nhưng không ai bắn

`screenEndEvent: 'screen_exited'` có trong `types.ts`, `index.ts` (default),
`remote-config.ts` (map), và `snowplow.ts` (case xử lý) — nhưng **không chỗ nào
emit nó**.

Hệ quả: không tính được thời gian ở lại mỗi màn (dwell time). Native có
`screen_start`/`screen_end` + `dwell_ms` do core bắn. Web thiếu hẳn nhánh này.

Snowplow có `enableActivityTracking` (page ping) cho mục đích tương đương.

---

## 🟠 P4 — `screen_load_completed` thiếu ở lần vào trang đầu

Đo trong session `1a4e769c`: `screen_viewed` = 13 nhưng `screen_load_completed` = 11.
Thiếu đúng 2 — khớp với 2 lần `app_start` (1 navigate + 1 reload).

Nguyên nhân: `emitScreen()` ở nhánh initial chỉ bắn khi `loadEventEnd > 0`, mà
lúc script chạy `load` chưa xong → `loadMs = 0` → bỏ qua. Cùng gốc với bug
`start_ms: 0` đã sửa hôm qua, nhưng chỗ này còn sót.

**Sửa:** dùng lại fallback `domContentLoadedEventEnd` như `app_start`.

---

## 🟠 P5 — Không có sampling / consent / opt-out

Grep toàn source: **không có** `samplingRate`, `consent`, `doNotTrack`, `optOut`.

- Native SDK **có** sampling (tài liệu overview ghi rõ "0.0–1.0, crash luôn 100%").
  Web không có → app triệu DAU không giảm tải được.
- Không có API tắt tracking khi user từ chối cookie. GDPR/CCPA phải tự xử ở tầng app.

Snowplow có `enableAnonymousTracking()`, consent plugin, `respectDoNotTrack`.

---

## 🟠 P6 — `reset()` không xoay session, không xoá queue

`reset()` chỉ xoá `identifiedUserId` trong RAM. Sau logout:
- `session_id` **giữ nguyên** → event của user mới vẫn chung session với user cũ
- Event của user cũ còn trong buffer vẫn được gửi đi

Native `reset()` xoay session. Đây là lỗ rò định danh giữa hai người dùng trên
cùng máy.

**Sửa:** `reset()` gọi `session.rotate('manual')`.

---

## 🟡 Thiếu so với Snowplow (chưa phải bug, là khoảng trống tính năng)

| Tính năng | Snowplow | UniTrack web |
|---|---|---|
| **Activity / page ping** (`enableActivityTracking`) | ✅ plugin | ❌ — không đo được engagement thật |
| **Form tracking** (focus/change/submit từng field) | ✅ plugin | ❌ chỉ bắt click nút submit |
| **Web Vitals** (LCP / CLS / INP) | ✅ plugin | ❌ chỉ có `load_ms` thô |
| **Media tracking** (video/audio) | ✅ plugin | ❌ |
| **Cross-domain linking** | ✅ `crossDomainLinker` | ❌ sang domain khác là mất session |
| **Anonymous tracking** | ✅ `enableAnonymousTracking` | ❌ |
| **Link click tracking** riêng | ✅ plugin | ⚠️ gộp chung vào `click` |
| **Button click tracking** riêng | ✅ plugin | ⚠️ gộp chung vào `click` |

Thiếu thêm (không bên nào là chuẩn, nhưng thị trường hay có): rage click, dead
click, scroll depth.

---

## ✅ Chỗ UniTrack web làm tốt hơn

| | Snowplow | UniTrack web |
|---|---|---|
| Auto-capture tap | cần bật plugin | ✅ sẵn, có gate lọc container |
| Network request | ❌ không có | ✅ fetch + XHR, có `duration_ms` + `status_code` |
| Crash / unhandled rejection | ❌ cần plugin | ✅ sẵn |
| Lifecycle (foreground/background) | ⚠️ gián tiếp qua page ping | ✅ `visibilitychange` + `background_sec` |
| W3C trace context | ❌ | ✅ fail-closed allowlist |
| PII hash sẵn trong SDK | ❌ tự làm | ✅ SHA-256 + salt |
| Setup | nhiều plugin rời | ✅ một lần `initialize()` |

**Đã kiểm chứng an toàn** (session `1a4e769c`, 138 event): 0 email thô lọt ra,
0 số thẻ, 0 self-ingest loop, `user_id` là hash 64 ký tự, key click rác 0/75.

---

## Thứ tự đề xuất sửa

1. **P1 offline queue** — mất dữ liệu thật, sửa gọn (một lần `enqueue` trong catch)
2. **P2 trần buffer + backoff** — chặn phình RAM và DDoS ngược endpoint
3. **P6 `reset()` xoay session** — lỗ rò định danh, sửa một dòng
4. **P4 `load_ms`** — một dòng, cùng gốc bug đã sửa
5. **P3 `screen_exited`** — cần thêm logic, ảnh hưởng phân tích dwell time
6. **P5 sampling / consent** — cần chốt hướng sản phẩm trước

P1 + P2 + P6 + P4 nằm trong khoảng một buổi làm.

---

## Ghi chú về phương pháp

- P1, P2 đo trực tiếp trên https://mobix.asia/event-tracking-mobile/unitrack-web-demo/
- P4 lấy từ số liệu thật của session `1a4e769c` (138 event)
- P3, P5 xác minh bằng grep toàn source
- Phần Snowplow tra docs chính thức qua context7, không dựa vào trí nhớ
