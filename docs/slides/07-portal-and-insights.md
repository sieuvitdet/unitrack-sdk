---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 07/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Portal: **Snowplow Console** + **Firebase** + **Sentry** trong 1

URL: https://mobix.asia/event-tracking-mobile

| Tab | Chức năng |
|---|---|
| **Sessions** | Replay journey theo user/device; mỗi event timeline với click → screen → API |
| **Logs** | Stream realtime mọi event qua filter (event_name, screen, status) |
| **Wireframe** | Heatmap tap trên screenshot (sắp tới) |
| **Config (remote)** | Endpoint, Snowplow/Firebase block, event_names, entities, tracing |
| **Agent** | LLM agent đọc session → highlight bug/UX issue (Phase 4) |
| **Activity** | Per-project event volume + health score |

---

## Session IDE — đặc sản

App user mở app → portal hiển thị:

```
📱 RootTabsScreen                    [9:14:28]
   👆 camera_item_selected (camera_item)   [9:14:28] → cam_living_room
   
📱 LiveStreamScreen                  [9:14:29]
   ⏱  screen_load_completed         load_ms=270
   👆 stream_start                  [9:14:32]
   📡 POST /v1/cameras/.../authorize  200 (143ms)
   📡 GET  /v1/cameras/.../manifest   200 (89ms)
   ▶  camera_stream_started          channel=1
   ⚠  buffering 350ms                [9:14:34]
   ⏹  camera_stream_ended            watch_sec=12
   
📱 PairingScreen                     [9:14:50]
   👆 pairing_success
   ✅ camera_pairing_completed       cam_new_99
   📦 camera_registered              FPT-Cam V2
```

→ Backend dev không cần SSH vào device, không cần Bugsnag, không cần Firebase Console.

---

## Insights server-side (không cần app làm)

1. **Crash attribution** — `recovered_on_launch=true` + frame addresses → portal có thể symbolicate
2. **Funnel** — group events theo `event_name` (camera_pairing_started → completed → registered)
3. **Heatmap tap** — aggregate `element_key` + `class_name` qua nhiều session
4. **Latency P50/P95** — từ `event_api.duration_ms`
5. **TTFF distribution** — từ `camera_stream_first_frame.ttff_ms`
6. **Network failure rate** — count `status >= 400` per endpoint

Tất cả query SQLite trực tiếp ở portal, không cần BigQuery.

---

## Forward sang Snowplow collector

Portal có **sp_event_maps**: 1 row per event_name → iglu schema URI.

```
event_name              | mode             | schema                                   | forward
─────────────────────────────────────────────────────────────────────────────────────────
camera_pairing_completed| self_describing | iglu:vn.../event_result/jsonschema/1-0-0  | true
camera_item_selected    | self_describing | iglu:vn.../event_click/jsonschema/1-0-0   | true
```

Khi portal nhận event matching, **auto forward** vào Snowplow collector (`https://ftracking.fpt.vn`) với schema đúng.

→ App **không cần** Snowplow SDK trực tiếp nếu chỉ muốn dữ liệu chảy vào Snowplow.

---

## Live test

App RN demo vừa fire 28 events smoke test, portal nhận:

```
event_result | 19   (stream/pairing/share/AI…)
event_click  | 10   (camera_item/notif_clicked…)
screen_view  |  5
event_api    |  5   (TTFF/notification…)
event_session|  4
event_crash  |  1
```

Truy vấn SQL trên portal → mỗi event có `event_name` field business đúng.

→ Slide tiếp: [08 — Remote config](08-remote-config-power.md)
