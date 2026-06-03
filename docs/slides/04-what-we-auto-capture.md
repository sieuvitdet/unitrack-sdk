---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 04/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Auto-capture: 6 loại event miễn phí

App **chỉ cần init**, SDK tự fire:

| Event | Trigger | Payload |
|---|---|---|
| `click` | Mọi UIButton/View/Pressable nhận touch | element_key, screen, class_name, framework, package |
| `screen_view` | Navigation push/pop/replace | screen, load_ms (didLoad→didAppear), from_screen |
| `network_request` | Mọi HTTP outbound | url, method, status, duration_ms, request_bytes, response_bytes |
| `app_start` | Cold start | cold_start_ms, app_version, locale, model |
| `app_foreground` / `app_background` | Lifecycle | reason, dwell_sec |
| `crash` | Native signal trap (SIGSEGV/SIGTRAP/SIGABRT) | signal, signal_name, frames, recovered_on_launch |

---

## Click capture — chi tiết

iOS swizzle `UIControl.sendActions(for:)`:
- `element_key` = `accessibilityIdentifier` > tag > `className.methodName`
- `class_name` = FQCN (`UIKit.UIButton`)
- `framework` = `"uikit"`
- `package` = `Bundle(for:).bundleIdentifier`

Android wrap `View.OnClickListener`:
- `element_key` = `resource-id` > tag > class
- `class_name` = `target.javaClass.name`
- `framework` = parse từ FQCN (`androidx`/`material`/`flutter`/`app`)
- `package` = `cls.package?.name`

Flutter `GestureDetector` listener: tương tự, thêm `wrapper_class` cho CustomButton.

RN HOC wrap `Pressable`: `element` = `displayName`/`name`.

→ **Backend session IDE biết "user bấm vào nút loại gì, ở màn nào, khung React/Flutter/native nào"** mà app không cần khai báo.

---

## Network capture

iOS: `URLProtocol.registerClass(UniTrackURLProtocol.self)` + swizzle `URLSessionConfiguration.default`.
Android: OkHttp interceptor `UniTrackTracingInterceptor`.
Flutter: `HttpOverrides.global = UniTrackHttpOverrides()`.
RN: global `fetch` wrapper.

Payload:
```json
{
  "url": "https://api.fptlife.vn/v1/billing/invoices",
  "method": "GET",
  "status": 200,
  "duration_ms": 312,
  "request_bytes": 0,
  "response_bytes": 4823,
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"
}
```

`trace_id` (W3C Trace Context) tự inject header → backend log + app event có cùng id.

---

## Crash recovery — điểm sáng nhất

App crash giữa session (vd null deref):

```
T+0    [signal handler] SIGSEGV trapped
       → write file <docs>/crash-pending.json
         { "signal": 11, "signal_name": "SIGSEGV",
           "frames": ["0x1010…", "0x1020…"] }
       → re-raise signal → OS kills app

T+5s   User reopens app
T+5.1s [ut_init] reads crash-pending.json, deletes file
       → enqueue `crash` event → portal (HTTP queue)
       → stash for Flutter MethodChannel hand-off
       → Swift/Kotlin fan-out → Snowplow + Firebase
         payload includes recovered_on_launch: true
```

→ **App crash ≠ data crash.** FLifeTracker chỉ có Snowplow's `exceptionAutotracking` (chỉ bắt được Swift NSException, không bắt được signal).

---

## So sánh coverage

| Event | FLifeTracker | UniTrack |
|---|---|---|
| Button click | Manual gọi `.buttonClick(.label)` | Auto, 100% |
| Screen view | Manual `.screen(.name)` | Auto qua Navigation observer |
| Screen load_ms | Không có | Auto đo didLoad→didAppear |
| Network request | Manual `.networkCustom(...)` | Auto qua URLProtocol |
| Network latency | Không có | Auto duration_ms |
| App start | Snowplow lifecycle | Auto cold_start_ms |
| Crash (signal) | Snowplow exceptionAutotracking (chỉ NSException) | Auto + recovery next launch |
| Crash on launch flag | Không có | Auto attribute crash_on_launch=true nếu < 5s từ init |
| Memory warning | Không có | Auto fire |

→ Slide tiếp: [05 — How tap works](05-how-tap-works.md)
