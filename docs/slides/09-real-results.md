---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 09/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Kết quả thực tế: 4 demo apps đã chạy

| Demo | Platform | Status | Key milestone |
|---|---|---|---|
| `ios-camera-demo` | iOS Swift | ✅ live device | Crash recovery: signal → next launch fire |
| `android-camera-demo` | Android Kotlin | ✅ live device | JitPack publish; fan-out 2 providers |
| `flutter-tracking-app` | Flutter | ✅ live device | 30 events theo sheet taxonomy |
| `react-native-demo` | RN | ✅ live device | Convention layer + 28 smoke events |

Đều fire qua cùng `mobix.asia/event-tracking-mobile` portal.

---

## Demo Flutter — event mapping đầy đủ 30 sheet items

| # | Sheet event | Wire schema | event_name field |
|---|---|---|---|
| 1 | session_started | event_session | session_started |
| 2 | session_ended | event_session | session_ended |
| 3 | screen_viewed | screen_view | screen_load_completed |
| 5 | camera_stream_started | event_result | camera_stream_started |
| 7 | camera_stream_paused | event_result | camera_stream_paused |
| 8 | camera_event_viewed | event_click | camera_event_viewed |
| 11 | notif_permission_checked | event_result | notification_permission_checked |
| 14 | notif_clicked | event_click | camera_notification_clicked |
| 15 | ai_feature_toggled | event_result | camera_ai_feature_toggled |
| 22 | pairing_started | event_result | camera_pairing_started |
| 27 | stream_first_frame | event_api | camera_stream_first_frame |
| 29 | camera_item_selected | event_click | camera_item_selected |
| 30 | application_error | event_crash | application_error |

→ **6 schemas cover 30 business events.**

---

## Bench Android camera-demo

Run trên Xiaomi Android 15:

```
Tap LIVING ROOM    → event_click   (5ms từ tap → flush queue)
Force crash (kill -SEGV)
Relaunch app
   → ut_init reads crash-pending.json
   → fan-out recovered crash to 2 provider(s)
   → Snowplow envelope: signal=11, signal_name=SIGSEGV, recovered_on_launch=true
   → Firebase MIRROR → portal (5110b POST)
   → Portal queue: httpPost mobix.asia/v1/events → 200

crash-pending.json sau pop = deleted (single-shot)
```

Lần test thật trên device, 100% events nhận đủ ở cả 3 backends.

---

## Storage cost

Repo source code: **31MB** (sau cleanup)
APK Android demo: **~12MB** (debug, có Snowplow + Firebase + UniTrack)
IPA iOS demo: **~18MB**
SDK JS bundle RN: **~80KB minified**
SDK AAR Android: **~150KB** (1 ABI)
Portal Node.js DB: **~50KB** sau 28 events smoke test

So với FLifeTracker không có portal: Snowplow plugin ~200KB + Firebase ~2MB native.
UniTrack overhead so với chỉ Snowplow + Firebase: **+50KB Swift / +80KB Kotlin** (acceptable).

---

## Performance

| Metric | Đo trên Xiaomi |
|---|---|
| Cold-start overhead | +12ms (ut_init + config fetch async) |
| Track call latency | <1ms (in-memory enqueue + async flush) |
| Network batch size | 5-50 events / POST (config-driven) |
| Flush interval | 3000ms default, override portal |
| Memory footprint | ~2.5MB (queue SQLite + provider state) |
| Battery impact | Negligible (background thread, no wake-up) |

→ Slide tiếp: [10 — Roadmap](10-roadmap.md)
