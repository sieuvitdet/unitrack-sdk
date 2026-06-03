---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 05/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Convention layer — 1 schema cho cả "kind" event

5 convention kinds (+ custom):

| Kind | Default name (portal có thể đổi) | Khi nào dùng |
|---|---|---|
| `click` | `event_click` | User chạm vào UI control |
| `result` | `event_result` | Kết quả 1 action (pairing success/fail, save profile) |
| `screen_view` | `screen_view` | Mỗi lần navigate màn |
| `crash` | `event_crash` | Native crash + Dart/JS exception |
| `api` | `event_api` | Network-style timing (HTTP, RTSP, FCM push) |
| `session` | `event_session` | session_started / session_ended |

App gọi helper:
```swift
snowplow.trackingResultEvent(action: "camera_pairing", status: "success",
                              data: ["camera_serial": "cam_99"])
```

SDK tự build schema URI: `iglu:vn.fpt.ftel.snowplow/event_result/jsonschema/1-0-0`

---

## Vì sao chỉ cần 6 schema

Backend FPT Life hiện đang định nghĩa **30+ iglu schemas**:

```
iglu:com.snowplowanalytics.snowplow/button_click/jsonschema/1-0-0
iglu:com.snowplowanalytics.snowplow/network_error_event_custom/jsonschema/1-0-0
iglu:com.snowplowanalytics.snowplow/play_event_custom/jsonschema/1-0-0
iglu:com.snowplowanalytics.snowplow/pause_event_custom/jsonschema/1-0-0
iglu:com.snowplowanalytics.snowplow/end_event_custom/jsonschema/1-0-0
... 25 schema nữa
```

**Vấn đề**: schema mới = thêm vào Iglu Registry + cập nhật app. 2 nơi.

**UniTrack**: 6 generic schemas, business identifier nằm trong field `event_name`:

```json
{
  "schema": "iglu:vn.fpt.ftel.snowplow/event_result/jsonschema/1-0-0",
  "data": {
    "event_name": "camera_pairing_completed",  ← cái thay đổi
    "status": "success",
    "camera_serial": "cam_99"
  }
}
```

→ Thêm event mới: không sửa Iglu, không build app.

---

## Wire shape — Snowplow event hoàn chỉnh

```
─── Snowplow Tracking ───  (convention event="event_click")
{
  "endpoint": "https://ftracking.fpt.vn",
  "method": "trackSelfDescribingEvent",
  "event": {
    "schema": "iglu:vn.fpt.ftel.snowplow/event_click/jsonschema/1-0-0",
    "data": {
      "event_name": "camera_item_selected",   ← business signal
      "element_key": "camera_item_selected",
      "label": "cam_living_room",
      "screen": "CameraListScreen",
      "camera_serial": "cam_living_room"
    }
  },
  "contexts": [
    { "schema": "iglu:.../user_context/...",   ← auto entity
      "data": { "user_id": "...", "subscription_plan": "..." } },
    { "schema": "iglu:.../core_action/...",    ← auto entity
      "data": { "timestamp": "2026-…", "screen": "...", "element_key": "..." } }
  ]
}
```

`user_context` + `core_action` được **auto-attach** mỗi event. Không gọi tay.

---

## So sánh với FLifeTracker `SnowplowAnalyticsProvider`

FLifeTracker:
```swift
case AnalyticsEventName.actionCustom:
    guard let type = event.parameters["type"] as? ActionEventCustomType else { return }
    let schemaName = SnowplowActionSchemaMapper.schemaName(for: type)  // play/pause/end
    let data = event.parameters.filter { $0.key != "type" }
    let payload: [String: Any] = [
        "schema": SnowplowSchema.custom(schemaName),
        "data": data
    ]
    self.trackSelfDescribing(schema: SnowplowSchema.unstruct, payload: payload)
```

**Double-wrap** (`unstruct_event` ngoài, `play_event_custom` trong) — kỳ lạ, có thể bug.

UniTrack:
```swift
snowplow.trackingResultEvent(
    action: "video_action", status: "play", data: ["video_id": "..."]
)
```

Schema URI build tự động, không nested. Context entities tự attach.

---

## Custom kinds

App đặc thù cần kind ngoài 6 default? Portal config:

```json
{
  "event_names": {
    "click": "event_click",
    "ev_payment": "event_payment_complete",     ← custom
    "ev_error":   "event_unexpected_error"      ← custom
  }
}
```

Sau đó dùng code-gen CLI:
```bash
swift run unitrack-gen \
  --api-key utk_… \
  --config-url https://mobix.asia/event-tracking-mobile/config \
  --output ./MyApp/UniTrackGenerated.swift
```

Output: `trackingEvPayment(data:)` + `trackingEvError(data:)` helper typed, IDE autocomplete.

→ Slide tiếp: [06 — Fan-out providers](06-fan-out-providers.md)
