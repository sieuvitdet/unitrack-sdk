# UniTrack Camera Demo — Android

Parity twin of `ios-camera-demo/`. Same 30 events, same portal (pid=3,
api_key `utk_6yC71Z4ZgPSIysijkh-ACf9g`), same 5-tab layout.

## What's in it

| Layer | File |
|-------|------|
| Application entry — fetch portal config, init SDK | `app/src/main/java/.../DemoApp.kt` |
| Bootstrap + Snowplow/Firebase providers + 30 helpers | `app/src/main/java/.../CameraAnalytics.kt` |
| 5-tab navigation host | `app/src/main/java/.../MainActivity.kt` |
| All 5 fragments (Cameras / VMS / Pairing / Alerts / Settings) | `app/src/main/java/.../fragments/Fragments.kt` |
| Local SDK module references | `settings.gradle` |

## Build

```bash
cd android-camera-demo
./gradlew :app:installDebug
adb shell am start -n ftel.isc.mobinetnextgen.staging/com.unitrack.camerademo.MainActivity
```

The demo links the **local** SDK modules:

```
:unitrack          → ../platforms/android/unitrack
:unitrack-firebase → ../platforms/android/unitrack-firebase
:unitrack-snowplow → ../platforms/android/unitrack-snowplow
```

So SDK source edits are picked up without publishing to mavenLocal.

## Firebase setup

No `google-services.json` is shipped. The Firebase provider is configured at
RUNTIME from `firebase.options` in the portal config — same as the iOS demo
runs without GoogleService-Info.plist baked in. The portal sends `appId`,
`gcmSenderId`, `apiKey`, `projectId`, `bundleId`, `storageBucket`.

## Verbose logging

```kotlin
UniTrack.verboseLogging = true   // default — every event prints to logcat
UniTrack.verboseLogging = false  // mute before shipping release
```

Filter logcat in Android Studio: `tag:UniTrack tag:UniTrackSnowplow tag:UniTrackFirebase`.

Sample output on a single button tap:

```
I/UniTrack: track event="camera_item_selected" props={"camera_serial":"cam_living_room",...} → providers=[SnowplowProvider,FirebaseProvider]
I/UniTrackSnowplow:
─── Snowplow Tracking ───  (blueprint="click_event" event="camera_item_selected")
{
  "endpoint": "https://ftracking.fpt.vn",
  "method":   "trackSelfDescribingEvent",
  "event":    { "schema": "iglu:vn.fpt.ftel.snowplow/ev_click/jsonschema/1-0-0", "data": {...} },
  "contexts": [ {schema, data}, {schema, data} ]
}
I/UniTrackFirebase: SEND event="camera_item_selected" (sanitized="camera_item_selected") params={...}
I/UniTrackFirebase: MIRROR → portal url=https://mobix.asia/...?provider=firebase bytes=412
```

## Smoke test

Drain all 30 events without driving the UI:

```bash
adb shell setprop unitrack.autofire 1
adb shell am force-stop ftel.isc.mobinetnextgen.staging
adb shell am start -n ftel.isc.mobinetnextgen.staging/com.unitrack.camerademo.MainActivity
```

`DemoApp.onCreate` reads the system property and calls
`CameraAnalytics.fireAllForSmokeTest()` 1.5s after launch.

## Crash test

Tap "🧨 Force real crash" in the Alerts tab. The app dies (SIGTRAP from
Kotlin's array-bounds check), and on next launch the SDK's signal handler
recovers `crash-pending.json` from `filesDir/` and posts a `crash` event to
the portal within ~3s.

App code does nothing analytics-related at the crash site — automatic
crash capture is the whole point.
