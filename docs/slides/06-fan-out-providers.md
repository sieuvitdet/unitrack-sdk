---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 06/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Fan-out: 1 event → N providers

App gọi 1 lần:
```swift
UniTrack.track("camera_pairing_completed", properties: [...])
```

SDK chia 3 đường song song:

```
                  ┌─→ Snowplow provider → ftracking.fpt.vn (iglu schema)
                  │
UniTrack.track ──┼─→ Firebase Analytics provider (logEvent + audience)
                  │                            └─→ portal mirror (provider=firebase)
                  │
                  └─→ Portal HTTP queue → mobix.asia/events
```

Mỗi provider **isolated**: 1 cái fail không break cái khác.

**Scope của Firebase provider**: chỉ Firebase **Analytics**. Trước đây có helper UniTrackFirebaseMessaging / UniTrackFirebaseCrashlytics / UniTrackFirebaseRemoteConfig — đã gỡ ở 0.4.0 để giữ SDK đúng định vị "tracking là sản phẩm". App nào cần Messaging / Crashlytics / RemoteConfig thì wire Firebase SDK trực tiếp — UniTrack đứng ngoài.

---

## So sánh code

**FLifeTracker — bắt buộc viết 2 provider class:**

```swift
final class SnowplowAnalyticsProvider: AnalyticsProvider {
    func track(event: AnalyticsEvent) {
        switch event.name {
        case AnalyticsEventName.buttonClick: …  // viết riêng
        case AnalyticsEventName.screenView:  …  // viết riêng
        case AnalyticsEventName.actionCustom: … // viết riêng
        case AnalyticsEventName.networkCustom: …// viết riêng
        }
    }
}

final class FirebaseAnalyticsProvider: AnalyticsProvider {
    func track(event: AnalyticsEvent) {
        switch event.name {
        case AnalyticsEventName.buttonClick: …  // viết riêng (lại)
        case AnalyticsEventName.screenView:  …  // viết riêng (lại)
        case AnalyticsEventName.actionCustom: … // viết riêng (lại)
        case AnalyticsEventName.networkCustom: …// viết riêng (lại)
        }
    }
}
```

**UniTrack** — provider tự handle event tên gì:
```swift
UniTrack.addProvider(SnowplowProvider(endpoint: "…", appId: "…"))
UniTrack.addProvider(FirebaseProvider())
// Xong. Mọi event đều fan-out cả 2.
```

---

## Provider có sẵn

| Provider | Platform | Lợi ích |
|---|---|---|
| `SnowplowProvider` | iOS, Android, Flutter | Convention layer + iglu schema + entity context |
| `FirebaseProvider` | iOS, Android, Flutter, RN | **Firebase Analytics only.** Tự sanitize event name (≤40 char, alphanumeric); mirror copy về portal |
| Portal queue | All | Core C++ tự gửi qua HTTPS, batch, retry, offline |

App có thể **viết provider riêng**: `class MyProvider: AnalyticsProvider`.

---

## Crash recovery cross-provider

```
T+0   App crash (SIGSEGV)
      ─→ signal handler write crash-pending.json
      ─→ OS kills app

T+5s  User reopen
      ─→ ut_init → reads crash-pending.json
      ─→ stash JSON to memory
      ─→ providers init
      ─→ for p in providers: p.track("crash", recovered_props)
            ├── Snowplow.trackingCrash(...)
            └── Firebase Analytics.logEvent(name: "crash", ...)
      ─→ portal queue also flushes
```

→ App crash, ALL 3 backends (Snowplow + Firebase Analytics + portal) nhận crash event ở session sau. Không backend nào miss.

**Note**: UniTrack chỉ bắn `crash` như 1 **analytics event** sang Firebase Analytics. Nếu app muốn full crash report (stack trace, dSYM symbolicate, breadcrumbs) thì wire Firebase Crashlytics SDK trực tiếp — UniTrack không thay thế Crashlytics, cả 2 chạy song song độc lập.

FLifeTracker không có cơ chế recovery cross-provider này. Snowplow tracker plugin có `exceptionAutotracking` nhưng chỉ bắt NSException, không bắt được SIGSEGV/SIGTRAP.

---

## Recovery hand-off cho Dart (Flutter case riêng)

Native side stash crash JSON → Flutter MethodChannel push lên Dart → Dart fan-out tới Dart providers (unitrack_snowplow Dart package).

```
Native pop_recovered_crash() ──→ MethodChannel("onRecoveredCrash") ──→ Dart
                                                                       │
                                                                       └─→ Dart Snowplow
                                                                       └─→ Dart Firebase Analytics
```

Single-shot drain: 1 lần read xong xoá file. Race-free giữa C++ và Swift.

→ Slide tiếp: [07 — Portal](07-portal-and-insights.md)
