# UniTrack Android camera demo

A 5-tab camera/CCTV app that mirrors the iOS `ios-camera-demo` and exercises
**every** auto-capture + helper the UniTrack Android SDK offers. It depends on
the SDK modules by path (`:unitrack`, `:unitrack-snowplow`), so it builds the
native core (`libunitrack_jni.so`) too.

## Screens (each is auto-captured as a `screen_view`)

| Tab | Fragment / Activity | Domain events |
|-----|---------------------|---------------|
| Cameras | `CamerasFragment` → `LiveStreamActivity` | `camera_item_selected`, stream start/pause/stop/ended, first_frame, buffering, event_viewed, playback start/ended |
| VMS | `VmsFragment` | `vms_camera_connected/disconnected`, `vms_recording_played`, `vms_alert_viewed` |
| Thêm camera | `PairingFragment` | `camera_pairing_started/completed/failed`, `camera_registered` |
| Cảnh báo | `AlertsFragment` | notification sent/delivered/clicked + `captureFcm/captureOpened`, `application_error`, real `crash`, `json_parse_error`, `trackDeeplink/trackWebViewOpen/trackThirdPartyOpen` |
| Cài đặt | `SettingsFragment` | `camera_ai_feature_toggled` (Switch), `camera_shared/revoke`, `identify`, `reset` |

## What's auto-captured with ZERO per-screen code

- `screen_view` — every Fragment / Activity on resume (name = class name).
- `tap` — every button/switch. The view's **String tag** becomes the
  `element_key` (e.g. `stream_start`), which is why `Ui.button(...)` sets a tag.
- `network_request` — every OkHttp call through `DemoApp.http` (wrapped with
  `OkHttpTracker.attach`). `DemoApi` fires varied 200/4xx/5xx calls per action.
- `app_start`, `app_foreground`, `app_background`.
- `session_start` / `session_end` (journeyCapture).
- `memory_warning` — onTrimMemory pressure.

## What needs explicit calls (an SDK can't infer these)

- The camera domain events — all in `CameraAnalytics` (the single tracking
  surface, ported from the iOS `CameraAnalytics`).
- Notifications — `UniTrackNotifications.captureFcm/captureOpened` (Android has
  no auto-wrap of the notification manager, unlike iOS).
- **Crash** — Android's SDK does NOT auto-install a crash handler, so `DemoApp`
  chains a `Thread.UncaughtExceptionHandler` that tracks a `crash` event and
  flushes before the process dies.

## Remote config + providers

Config (ingest endpoint, Snowplow on/off, SDK flags, rewrite rules) is pulled
from the portal at launch via `UniTrackRemoteConfig.fetch(...)` — only the
`api_key` + config URL are hardcoded (in `CameraAnalytics`). When the portal
enables Snowplow, `SnowplowProvider` is added automatically.

Firebase is intentionally left out (the Android `FirebaseProvider` needs a
`google-services.json` + the google-services plugin). The enable path is
documented in `CameraAnalytics.start()`.

## Build & run

From `platforms/android` (the Gradle root):

```bash
../../scripts/fetch_sqlite.sh        # one-time: SQLite the native core links
./gradlew :demo:installDebug         # build + install (compiles the .so too)
# or: ./gradlew :demo:assembleDebug && adb install -r demo/build/outputs/apk/debug/demo-debug.apk
```

Tap around, then open the UniTrack portal → **Sessions** for your project to see
the journey, taps, network and crashes. (After "Gây crash", reopen the app so the
queued crash flushes.)
