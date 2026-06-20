# UniTrack SDK

Universal mobile analytics SDK — one codebase, four platforms. Auto-captures screens, taps, network requests, crashes, OOM events, and JSON parse errors. Persists events offline and flushes on network restore. Partners integrate with **one init call**.

## Why UniTrack

Three design goals shape every line of code in this repo:

1. **One source of truth, four platforms.** The pipeline (queue, batching, transport, session, sampling, dedup) lives in a single C++ core that ships to iOS, Android, React Native, and Flutter. Behaviour on every platform stays bit-for-bit consistent — fix a bug once, all four get it. Per-platform code is a thin binding (Swift / Kotlin / TS / Dart) that owns only what's truly platform-specific: swizzling, JNI, MethodChannel.
2. **Integrate in minutes, not weeks.** Drop the package in, write **one** init line, and screens / taps / network / crashes start flowing automatically — no per-event wiring required for the common case. Per-platform setup samples are below; each is ≤ 4 lines.
3. **Tracking is the product.** UniTrack is an analytics SDK. The optional Firebase provider mirrors events into **Firebase Analytics only** (so marketing keeps their funnels/audiences) — UniTrack doesn't wrap Firebase Messaging, Crashlytics, or Remote Config any more (those belong to the app's own Firebase setup, not the analytics layer).

```
                       ┌─────────────────────────────────┐
                       │   Native iOS  Native Android    │
                       │   React Native     Flutter       │
                       └────────────┬────────────────────┘
                                    │
                       ┌────────────▼────────────┐
                       │  Thin platform bindings │
                       │  (swizzle / JNI / RN /  │
                       │   Flutter MethodChannel)│
                       └────────────┬────────────┘
                                    │  ut_*() C ABI
                       ┌────────────▼────────────┐
                       │     C++ Shared Core     │
                       │  pipeline · queue ·     │
                       │  transport · session    │
                       └─────────────────────────┘
```

## Repo layout

```
unitrack-sdk/
├── core/                  C++ shared library (libunitrack)
│   ├── include/unitrack/  Public C API (unitrack.h)
│   ├── src/               Implementation
│   ├── third_party/       Bundled SQLite (fetched on demand)
│   └── CMakeLists.txt
│
├── platforms/
│   ├── ios/               Swift framework (SPM + CocoaPods)
│   ├── android/           Kotlin AAR (Gradle + NDK)
│   ├── react-native/      TS module + native bridges
│   └── flutter/           Dart plugin + native bridges
│
├── scripts/
│   ├── fetch_sqlite.sh
│   ├── build_ios.sh
│   ├── build_android.sh
│   ├── build_rn.sh
│   ├── build_flutter.sh
│   └── release.sh         master pipeline
│
├── tests/                 C++ test runner
├── examples/              one-file integration samples
└── .github/workflows/     CI matrix
```

## Build the core (host machine)

```bash
sudo apt-get install -y libsqlite3-dev cmake     # macOS: brew install cmake
cmake -S core -B build/host -DUT_BUILD_TESTS=ON
cmake --build build/host -j
./build/host/tests/unitrack_tests
```

Expected: `28 passed, 0 failed`.

## Build platform artifacts

```bash
./scripts/release.sh 1.0.0
```

Skips toolchains not installed locally. Outputs go to `dist/`:

| Artifact | Built by |
|---|---|
| `UniTrack.xcframework` | `xcodebuild` (macOS only) |
| `unitrack.aar` | Android Gradle + NDK |
| `unitrack-react-native-*.tgz` | `npm pack` |
| `unitrack` (pub.dev package) | `flutter pub publish --dry-run` |

## Integration — one call each

### iOS (Swift)
```swift
import UniTrack
UniTrack.initialize(apiKey: "YOUR_KEY")
```

### Android (Kotlin)
```kotlin
import com.unitrack.sdk.UniTrack
UniTrack.initialize(this, UniTrackConfig(apiKey = "YOUR_KEY"))
```

### React Native
```typescript
import UniTrack from '@unitrack/react-native';
await UniTrack.initialize('YOUR_KEY');
```

### Flutter
```dart
import 'package:unitrack/unitrack.dart';
await UniTrack.instance.initialize('YOUR_KEY');
```

On Flutter, the UI is drawn into a single native view, so the native tap/network
swizzlers can't see which Flutter widget was tapped. The SDK ships Dart-layer
auto-capture for this — declare it once and tap/screen/network are captured with
no per-widget code:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UniTrack.instance.initialize('YOUR_KEY',
      config: const UniTrackConfig(endpoint: '…'));

  UniTrack.installHttpAutoCapture();            // every API call/error + the tap that caused it

  runApp(UniTrackTapObserver(child: MyApp()));  // every tap (button name + screen) + screen_view
}

// In MaterialApp:
//   navigatorObservers: [UniTrackTapObserver.routeObserver],
```

The tapped button's name is resolved from `Semantics(identifier:)` → `ValueKey`
→ the button's text label → widget type — so even un-annotated buttons get a
meaningful name.

## What the SDK captures automatically

| Event | iOS | Android | RN | Flutter | How |
|---|---|---|---|---|---|
| screen_view | ✓ | ✓ | ✓ | ✓ | swizzle / lifecycle / nav observers |
| tap | ✓ | ✓ | partial | partial | UIControl swizzle / Window.Callback wrap |
| network_request | ✓ | ✓¹ | ✓ | ✓ | URLProtocol / OkHttp interceptor / fetch wrap |
| memory_warning | ✓ | ✓ | ✓ | ✓ | UIApplication notif / ComponentCallbacks2 |
| app_foreground / app_background | ✓ | ✓ | ✓ | ✓ | UIApplication / ActivityLifecycle |
| json_parse_error | helper | helper | helper | helper | `UniTrackDecoder` / `UniTrackJson.parse` / `safeJsonParse` |
| crash | hooks ready | hooks ready | — | — | signal handlers in core |

¹ Android requires `OkHttpTracker.attach(client)` for custom OkHttp clients.

## Element-key resolution

To make taps useful, give your interactive elements stable identifiers. The SDK falls back through this list:

| Platform | 1st choice | 2nd | 3rd | 4th |
|---|---|---|---|---|
| iOS | `accessibilityIdentifier` | `restorationIdentifier` | button title | `ClassName` |
| Android | `View.tag` (String) | resource entry name | `contentDescription` | TextView text |
| RN | `testID` | accessibilityLabel | component name | — |
| Flutter | semantic label | route + index | widget type | — |

## Event schema

Every event payload has the shape:

```json
{
  "event_id":   "uuid",
  "event_name": "tap",
  "timestamp":  1716234567890,
  "session_id": "uuid",
  "user_id":    "u-123",
  "screen":     "Home",
  "properties": { ... event-specific ... }
}
```

Batches POST to the configured `endpoint` as a JSON array.

## Configuration

```swift
var c = UniTrack.Config()
c.endpoint         = "https://ingest.example.com/v1/events"
c.batchSize        = 50         // events per HTTP POST
c.flushIntervalMs  = 5000       // background flush cadence
c.samplingRate     = 1.0        // 0.0–1.0
c.autoCapture      = true
c.trackScreens     = true
c.trackTaps        = true
c.trackNetwork     = true
c.logLevel         = .warn
```

Same keys are available in Kotlin (`UniTrackConfig`), RN (`UniTrackConfig` type), and Flutter (`UniTrackConfig` class).

## Offline behaviour

- All events persist to SQLite **before** the network attempt.
- On HTTP failure, events stay in queue with `retry_count` incremented.
- On `app_background`, a flush is requested.
- On network restore (caller-driven; SDK does not poll), the next batch goes out.
- Queue is trimmed by `max_queue_size` (default 10 000) and `max_age_days` (default 7).
- Events with `retry_count > 10` are dropped.

## Optional providers

UniTrack ships two opt-in providers that fan a copy of every event out to a third-party pipeline. Wire them once at init; the rest of the app keeps calling `UniTrack.track(...)`.

| Provider | What it does | When to add |
|---|---|---|
| `UniTrackSnowplow` | Forwards events to a Snowplow collector (self-described JSON, atomic schemas, entities). | You already operate a Snowplow pipeline for warehouse-grade analytics. |
| `UniTrackFirebase` | Mirrors events into **Firebase Analytics** (Console funnels, audiences, BigQuery export). | Marketing already uses Firebase Console and you don't want to maintain two SDKs to feed it. |

`UniTrackFirebase` is **Analytics-only**. Earlier releases shipped helper façades for Firebase Messaging / Crashlytics / Remote Config; those were removed in `0.4.0` / `1.1.0` to keep this SDK scoped to tracking. Apps that need those Firebase modules wire them directly — UniTrack stays out of the way.

## License

MIT
