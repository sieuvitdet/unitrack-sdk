# UniTrack cross-binary integration — Native ↔ Flutter

3 kịch bản tích hợp gây ra "2 SDK chạy song song" và cách giải.

## Vấn đề chung

Khi 1 iOS process có **2 binary** chứa class tên `UniTrack` nhưng ở **2 module Swift khác nhau**, mặc định chạy thành 2 singleton riêng:

```
Module "UniTrack" (SPM/Pod)         Module "unitrack" (Flutter plugin)
   ↓ class UniTrack {}                  ↓ class UniTrack {}
   ↓ singleton A                        ↓ singleton B
   ↓ ut_context A → SQLite A           ↓ ut_context B → SQLite B
   ↓ session_id AAA                    ↓ session_id BBB
   ↓ providers A (Snowplow native)     ↓ providers B (rỗng)
```

→ Portal thấy 2 session khác nhau cùng 1 user → không join được.

## Giải pháp: HostProxy + ObjC bridge (từ tag 0.3.46)

Plugin Flutter (`UniTrackPlugin.swift`) detect native SPM module qua `NSClassFromString("UniTrack.UniTrack")`. Khi tồn tại → **co-resident mode** → forward mọi MethodChannel call về **singleton native** qua ObjC runtime. Plugin không init UniTrack module-local.

Kết quả: 1 SDK duy nhất → 1 session_id, 1 SQLite, 1 provider list, 1 URLProtocol cho trace.

---

## Kịch bản 1 — Native iOS app embed Flutter module

VD: FPT Life iOS native, nhúng Flutter module qua `App.xcframework` build từ Flutter source riêng.

```
┌──────────── FPT Life iOS process ────────────┐
│  Swift code (chính)                          │
│   + UniTrack SPM 0.3.46                      │
│   + SnowplowProvider native                  │
│   UniTrack.initialize(apiKey: "...")         │
│                                              │
│  FlutterViewController nhúng vào             │
│   ↓ App.xcframework                          │
│   ↓ unitrack.xcframework (Flutter plugin)    │
│   ↓ unitrack pub.dev (Dart wrap)             │
│                                              │
│  Dart main.dart:                             │
│   runApp(UniTrackTapObserver(                │
│     child: MaterialApp(...)))                │
│   // KHÔNG cần gọi UniTrack.initialize ở     │
│   //   Dart — native đã init                 │
└──────────────────────────────────────────────┘
```

**Pipeline tap trong Flutter widget**:
1. User tap → `UniTrackTapObserver` (Dart) bắt
2. Dart gọi `UniTrack.instance.track('click', ...)` → MethodChannel "unitrack" `track`
3. `UniTrackPlugin.handle` → `UniTrackHostProxy.isCoResident == true` → `handleCoResident`
4. ObjC perform selector `objc_track:propertiesJson:` lên **NATIVE UniTrack class**
5. Native SDK fire qua SnowplowProvider FPT Life đã add → Portal pid=8

✅ session_id native = session_id Dart (cùng singleton). ✅ Snowplow nhận event. ✅ SQLite offline queue duy nhất.

---

## Kịch bản 2 — Flutter app + 1 native iOS xcframework có UniTrack

VD: 1 Flutter app, DEV add native module `RogoCore.xcframework` (hoặc tự code Swift native trong `ios/Runner`) — native code link UniTrack SPM riêng.

```
┌──────────── Flutter app process ────────────┐
│  Dart code (chính)                          │
│   + unitrack pub.dev (Dart wrap)            │
│   + unitrack.xcframework (Flutter plugin)   │
│                                             │
│  ios/Runner/AppDelegate.swift (custom):     │
│   import UniTrack    ← SPM 0.3.46            │
│   UniTrack.initialize(apiKey: "utk_...")    │
│                                             │
│  Hoặc:                                      │
│  CustomLib.xcframework link UniTrack SPM,   │
│  gọi UniTrack.track(...) cho event của lib  │
└─────────────────────────────────────────────┘
```

**Pipeline**:
- Native code init UniTrack singleton A
- Plugin Flutter detect `NSClassFromString("UniTrack.UniTrack")` → co-resident → route call về singleton A
- Dart `UniTrack.instance.initialize()` no-op (Plugin skip, log "co-resident")

✅ Cùng singleton. ✅ Native event + Dart event chung session, chung Portal queue.

---

## Kịch bản 3 — Flutter app + native xcframework KHÔNG dùng UniTrack

VD: Flutter app link RogoCore.xcframework — RogoCore tự code Firebase Analytics, không biết UniTrack.

```
Flutter app
  ↓ Dart UniTrack singleton (Plugin module-local)
  ↓ session_id BBB, sends → Portal

RogoCore.xcframework
  ↓ Firebase Analytics calls
  ↓ Không qua UniTrack
  ↓ Events → Firebase Console (riêng)
```

→ **2 hệ thống độc lập** vì RogoCore không gọi UniTrack.

**Cách bridge nếu cần unify**:

**Option A** — RogoCore expose @objc API, Dart bridge gọi:
```swift
// Trong RogoCore (sửa source):
@objc public static func reportEvent(_ name: String, props: [String: Any]) {
    // RogoCore logic + report
    // → emit qua UniTrack
    UniTrack.track(name, properties: props)
}
```
Dart side gọi qua MethodChannel custom → vào RogoCore → tự fire UniTrack.

**Option B** — Native side intercept Firebase logEvent qua swizzle (tương tự FirebaseAdapter):
```swift
// Native code (AppDelegate.swift):
import UniTrack
// Hook FIRAnalytics.logEvent — mỗi call cũng fire UniTrack.track
SwizzleFirebaseAnalytics.install { name, params in
    UniTrack.track(name, properties: params)
}
```

→ Mọi event Firebase RogoCore gửi cũng tự động vào UniTrack pipeline. **Khuyến nghị Option B** vì không cần đụng source RogoCore.

---

## Kịch bản 4 — Flutter app pure (chỉ Dart, không có native code)

Không có vấn đề. Plugin Flutter chạy bình thường, 1 singleton module-local. session_id Dart = duy nhất.

---

## Bảng tóm tắt parity

| Aspect | Kịch bản 1 (FPT Life style) | Kịch bản 2 (Flutter+Custom native UniTrack) | Kịch bản 3 (Flutter+3rd-party SDK) | Kịch bản 4 (Flutter pure) |
|---|---|---|---|---|
| Init point | Native swift gọi initialize | Native Runner Swift gọi initialize | Dart gọi initialize | Dart gọi initialize |
| session_id | Cùng (native) | Cùng (native) | Khác (UniTrack vs Firebase) | Duy nhất (Dart) |
| SQLite offline | 1 file native | 1 file native | 1 file UniTrack + 1 file Firebase nội bộ | 1 file Dart-plugin |
| Trace W3C native HTTP | URLProtocol native inject | URLProtocol native inject | URLProtocol native inject | Không có (Dart HTTP) |
| Trace W3C Dart HTTP | UniTrackHttpClient inject | UniTrackHttpClient inject | UniTrackHttpClient inject | UniTrackHttpClient inject |
| Provider (Snowplow, Firebase) | Native add → Flutter event auto qua | Native add → Flutter event auto qua | Native không add — Dart side phải tự add provider | Dart-side add provider |
| Code change cần | None (sau 0.3.46) | None (sau 0.3.46) | Bridge swizzle 3rd-party SDK | None |

---

## Sync trace_id giữa Native HTTP + Flutter HTTP

Mỗi side mint trace_id riêng (Dart `UniTrackTraceContext.newTrace`, Native `UniTrackTracing.newTrace`). 2 trace_id KHÔNG link nhau vì là 2 root span độc lập.

Nếu cần parent-child trace (Flutter call native code → native call API):
1. Dart mint trace_id `T1` → send qua MethodChannel
2. Native nhận `T1`, dùng làm parent → mint span_id mới `S2` cho call API native
3. Native HTTP: header `traceparent: 00-T1-S2-01`

Em đã support pattern này qua `UniTrackTraceContext.fromParent(traceId:)` (cần verify thêm).

→ **Default**: 2 trace_id rời nhau. **Wire manually** nếu cần parent-child.

---

## Backward-compat

- App KHÔNG có native UniTrack SPM (chỉ Flutter plugin) → `isCoResident == false` → Plugin tự manage singleton module-local. Như trước.
- App có native UniTrack SPM phiên bản < 0.3.46 (chưa có `objc_*` methods) → HostProxy gọi `responds(to:)` check trước, false → log warning, no-op. Không crash.

→ Update tag 0.3.46 NON-BREAKING cho cả 2 đầu.
