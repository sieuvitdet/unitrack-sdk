# UniTrack Camera Demo (native iOS / UIKit)

A native **UIKit** app that exercises the full **camera/CCTV event taxonomy**
(30 events) against the UniTrack SDK, integrated via a **remote Swift Package**
(`github.com/sieuvitdet/unitrack-ios-package`, branch `main`). It doubles as an
honest assessment of how well UniTrack drops into a real native iOS app.

## Run it

```bash
cd ios-camera-demo
gem install xcodeproj          # one-time, for the generator

# A) Simulator (no signing):
ruby gen_project.rb

# B) Real device (Apple Developer Team ID — Xcode ▸ Settings ▸ Accounts):
# DEV_TEAM=ABCDE12345 ruby gen_project.rb

open UniTrackCameraDemo.xcodeproj   # Xcode resolves the Swift Package on open
```

Xcode fetches the package and its products **UniTrack / UniTrackFirebase /
UniTrackSnowplow** (Firebase + Snowplow are transitive deps). First open may
take a moment to resolve packages. Then Build & Run.

Events flow to https://mobix.asia/event-tracking-mobile (admin@mobix.asia).

> **"The executable is not codesigned"** = ran on a real device with the
> Simulator (unsigned) project. Pick a Simulator, or regenerate with
> `DEV_TEAM=<your_team_id>`.

## App structure (5 tabs)

| Tab | Screen | Taxonomy exercised |
|---|---|---|
| Cameras | `CameraListScreen` → `LiveStreamScreen` | item select, stream start/pause/end, first-frame, buffering, event view, playback |
| VMS | `VMSScreen` | vms connect/disconnect, recording played, alert viewed |
| Add Camera | `CameraPairingScreen` | pairing started/completed/failed, camera registered |
| Alerts | `AlertsScreen` | notification permission/sent/delivered/clicked, application_error, real crash |
| Settings | `CameraSettingsScreen` | AI feature toggled, camera shared/revoked |

All domain events funnel through `CameraAnalytics.swift` — the single tracking
surface.

## Coverage matrix — 30 taxonomy events

| # | Event | How it's captured | Auto / Manual |
|---|---|---|---|
| 1 | session_started | `CameraAnalytics.sessionStarted()` at launch/foreground | Manual* |
| 2 | session_ended | on `applicationDidEnterBackground` | Manual* |
| 3 | screen_viewed | **auto** `screen_view` (ViewController swizzle) + explicit name | Auto |
| 4 | screen_exited | derived from next screen_view; explicit available | Auto/Manual |
| 5 | camera_stream_started | `streamStarted()` | Manual |
| 6 | camera_stream_ended | `streamEnded()` (also on screen leave) | Manual |
| 7 | camera_stream_paused | `streamPaused()` | Manual |
| 8 | camera_event_viewed | `eventViewed()` | Manual |
| 9 | camera_playback_started | `playbackStarted()` | Manual |
| 10 | camera_playback_ended | `playbackEnded()` | Manual |
| 11 | notification_permission_checked | `notificationPermissionChecked()` | Manual |
| 12 | camera_notification_sent | `notificationSent()` | Manual |
| 13 | camera_notification_delivered | `notificationDelivered()` | Manual |
| 14 | camera_notification_clicked | `notificationClicked()` + **auto** via `UniTrackNotifications.wrap()` | Manual/Auto |
| 15 | camera_ai_feature_toggled | `aiFeatureToggled()` (UISwitch) | Manual |
| 16 | vms_camera_connected | `vmsCameraConnected()` | Manual |
| 17 | vms_camera_disconnected | `vmsCameraDisconnected()` | Manual |
| 18 | vms_recording_played | `vmsRecordingPlayed()` | Manual |
| 19 | vms_alert_viewed | `vmsAlertViewed()` | Manual |
| 20 | camera_shared | `cameraShared()` | Manual |
| 21 | camera_share_revoked | `cameraShareRevoked()` | Manual |
| 22 | camera_pairing_started | `pairingStarted()` | Manual |
| 23 | camera_pairing_completed | `pairingCompleted()` | Manual |
| 24 | camera_pairing_failed | `pairingFailed()` | Manual |
| 25 | camera_registered | `cameraRegistered()` | Manual |
| 26 | screen_load_completed | `TrackedViewController` viewDidAppear timing | Manual (1 base class) |
| 27 | camera_stream_first_frame | `streamFirstFrame()` | Manual |
| 28 | camera_stream_buffering | `streamBuffering()` | Manual |
| 29 | camera_item_selected | `cameraItemSelected()` + **auto** `tap` | Manual/Auto |
| 30 | application_error | `applicationError()` for handled; **auto** `crash` for real crashes | Manual/Auto |

\* session events are emitted by the demo from app lifecycle (see Gaps).

Plus, captured **for free** with zero code: every button `tap` (keyed by
`accessibilityIdentifier`), every `screen_view`, every `network_request`
(the API buttons), `app_foreground`/`app_background`, `app_start`, and `crash`.

## Assessment — applying UniTrack to a real native iOS app

**What works out of the box (high value, zero code):**
- `screen_view` for every UIViewController (uses `title` or class name) — covers
  navigation analytics for a UIKit app with no instrumentation.
- `tap` for every UIControl, keyed by `accessibilityIdentifier`. Real apps that
  already set accessibility IDs get meaningful tap analytics for free.
- `network_request` for all URLSession traffic (query/headers/bodies redacted).
- App lifecycle, cold-start time, and native crash capture (signal handler).
- Rich device metadata on every event (model, OS, locale, network type incl.
  3G/4G/5G, jailbreak, debug flag, app/bundle version).

**What needs explicit calls (expected for any analytics SDK):**
- All domain/business events (the camera-specific 25 of 30). No SDK can infer
  "live stream started" from UIKit — these are one-liner `track()` calls.
  Centralizing them in `CameraAnalytics.swift` keeps the taxonomy in one file.

**Gaps found vs. this taxonomy (and how the demo handles them):**
1. **No session_started / session_ended events.** UniTrack keeps an implicit
   `session_id` (30-min idle rotation) but emits no session events. The demo
   emits them from `application(_:didFinishLaunching…)` / `didEnterBackground`.
   → *Recommendation:* add optional session lifecycle events to the SDK core.
2. **Notification model is received/opened only.** The taxonomy wants
   permission/sent/delivered/clicked (4 states). `UniTrackNotifications.wrap()`
   auto-captures received+opened; the other three are explicit. → *Recommendation:*
   richer notification helper, or document the manual pattern (done here).
3. **SwiftUI not covered by auto-capture.** The swizzlers hook UIKit; a SwiftUI
   app would need manual `setScreen`/`track` almost everywhere. This demo is
   UIKit precisely because that's where auto-capture shines.

**Effort to adopt in a production native iOS app:**
- Integration: ~10 min (add pod, one `initialize()` call, wrap notif delegate).
- Free coverage immediately: screens, taps, network, lifecycle, crash, device.
- Per-event work: one `track()` line per business event, ideally behind a thin
  `Analytics` enum like `CameraAnalytics` here (≈ the 25 domain methods).
- No third-party dependency unless you opt into Snowplow/Firebase providers.

**Verdict:** UniTrack is a good fit for a UIKit camera app. ~5 of 30 events come
free; the remaining domain events are trivial one-liners centralized in one
file. The two real gaps (session events, fuller notification model) are small,
well-scoped SDK additions rather than blockers.
