---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 08/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Remote config: **đổi không cần build**

App fetch config 1 lần ở init:
```
GET https://mobix.asia/event-tracking-mobile/config
Authorization: Bearer utk_…
```

Response:
```json
{
  "version": 14,
  "endpoint": "https://mobix.asia/event-tracking-mobile/v1/events",
  "sdk_config": {
    "batchSize": 10,
    "trackTaps": false,           ← bật/tắt auto-tap
    "trackNetwork": true,
    "screen_load_event": "screen_view"
  },
  "snowplow": {
    "enabled": true,
    "endpoint": "https://ftracking.fpt.vn",
    "iglu_vendor": "vn.fpt.ftel.snowplow",
    "event_names": { "click": "event_click", "result": "event_result", … },
    "entities":    { "user_context": "...", "core_action": "..." }
  },
  "firebase": { "enabled": true, "super_properties": {…} },
  "tracing":  { "enabled": true, "allowlist_hosts": ["*.fpt.vn"] }
}
```

---

## Use case 1 — Tắt tap auto-capture

App test thấy mỗi tap fire 2 event (1 auto + 1 business).

**Hiện trạng FLifeTracker**: phải sửa SnowplowService rồi ship app.

**UniTrack**: portal → tab Config → uncheck `trackTaps` → Save → user mở app lần sau (force-stop relaunch) → tự fetch config mới. **0 dòng code thay đổi.**

---

## Use case 2 — Đổi tên event_click → event_isc_click

Sheet taxonomy mới đổi tên ev_click thành event_isc_click.

**FLifeTracker**: sửa `SnowplowSchema.buttonClick` URI → ship app → đợi user update qua App Store.

**UniTrack**: portal → Config → Snowplow → event_names → `click: event_isc_click` → Save → app mở lần sau pick up.

→ Backend taxonomy migration không phụ thuộc app release cycle.

---

## Use case 3 — Project Flutter copy config từ Camera demo

Anh setup xong Camera demo (pid=3). Tạo project Flutter mới (pid=12).

**FLifeTracker**: không có khái niệm này.

**UniTrack**: portal → Camera demo → tab Config → **⬇︎ Export JSON** → file bundle.
Sang Flutter project → **⬆︎ Import JSON** → file. → All sdk_config + Snowplow + Firebase + sp_event_maps clone.

```bash
# Sản phẩm download:
unitrack-config-camera-demo-v14.json   3KB
```

Bundle shape:
```json
{
  "bundle_kind": "unitrack_project_config",
  "bundle_version": 1,
  "config": {
    "endpoint": "...", "sdk_config": {...}, "snowplow": {...},
    "firebase": {...}, "tracing": {...}
  },
  "sp_event_maps": [...]
}
```

---

## Use case 4 — A/B test feature flag

Không phải feature core nhưng UniTrack có thể stage:

1. Portal → flavor `beta` → override `sdk_config.samplingRate: 0.5` (sample 50%)
2. App build flavor `beta` gửi header `X-UniTrack-Flavor: beta`
3. Server merge override per-flavor → chỉ beta users bị sample

→ Roll out tracking gradual mà không cần build lại app.

---

## Cache + ETag

App fetch config qua **ETag**:
```
GET /config
If-None-Match: "cfg-3-v14-base"
```
Server trả 304 Not Modified nếu version chưa đổi → tiết kiệm bandwidth + battery.

App cache config local (UserDefaults / SharedPreferences / Hive) → lần init sau dùng cached config nếu mạng fail → app vẫn boot đầy đủ tracking.

→ Slide tiếp: [09 — Real results](09-real-results.md)
