# Mobix Tracking Demo (Flutter + UniTrack)

A Flutter app that integrates the **UniTrack SDK** (from this repo) and exercises
every kind of event the SDK can produce, shipping them live to the Mobix portal:

> **https://mobix.asia/event-tracking-mobile**

Open that URL in a browser to watch events arrive in real time.

## Zero per-screen tracking — it's all in `main.dart`

The demo screens contain **no tracking code** — they are plain UI. Everything is
captured by three declarations at startup:

```dart
await Tracking.init();                          // 1. SDK + transport
HttpOverrides.global = UniTrackHttpOverrides();  // 2. every API call/error
runApp(const UniTrackTapObserver(child: app));   // 3. every tap + screen
```

Add a new screen, button, or API call and it is tracked automatically — no new
tracking code. What you get:

- **screen_view** — which screen the user is on (route name).
- **tap** — which button on which screen. The button name is resolved from
  `Semantics(identifier:)` → `ValueKey` → the button's text label
  (e.g. "Thanh toán") → widget type. So even buttons with no annotation get a
  meaningful name.
- **network_request / network_error** — every HTTP call with method/host/path/
  status/duration, **mirrored with the button + screen that triggered it**
  (`triggered_by_element`, `triggered_by_screen`). Try the "GET 404" / "Bad
  host" buttons on the Network screen to see a failure attributed to its button.

### Why this lives in Dart, not the native SDK

The native SDK's tap/network swizzlers (iOS `ControlSwizzler`, Android
`Window.Callback`) work for native UI, but Flutter renders its whole UI into a
single native view — so native swizzling cannot see which Flutter widget was
tapped. Capturing the widget name requires intercepting in the Dart layer, which
is what `UniTrackTapObserver` / `UniTrackHttpOverrides` do. They still push every
event through the SDK (`UniTrack.track`), so the SDK handles all of the heavy
lifting: batching, the offline queue, sessions, and transport to the portal.

## What it tracks (event reference)

The SDK captures two layers of events.

**Automatic (native auto-capture)** — no code per screen:

| Event | How |
|---|---|
| `screen_view` | `UniTrackNavigatorObserver` + each screen's `setScreen()` |
| `tap` | native UIControl swizzle (iOS) / Window.Callback (Android), keyed by `Semantics(identifier:)` |
| `network_request` | URLProtocol (iOS) / OkHttp interceptor (Android) — see the Network demo screen |
| `app_foreground` / `app_background` | app lifecycle |
| `memory_warning` | OS memory pressure |
| `crash` | native signal handler (Settings → "Gây crash") |

**Manual business events** fired by the screens, e.g.:

`app_launched`, `login_attempt`, `login_success`, `login_failed`,
`product_list_viewed`, `category_filter_applied`, `product_clicked`,
`product_viewed`, `add_to_cart`, `cart_viewed`, `remove_from_cart`,
`begin_checkout`, `payment_method_selected`, `add_payment_info`,
`purchase`, `checkout_abandoned`, `json_parse_error`, `rated_app`,
plus a 20-event burst from Settings.

## The flows (screens)

```
Login ─▶ Home ┬─▶ ProductList ─▶ ProductDetail ─▶ (add) ─▶ Cart ─▶ Checkout ─▶ purchase
              ├─▶ Cart
              ├─▶ Network demo (GET/POST/404/broken-JSON)
              └─▶ Settings (toggle tracking, identify, burst, crash)
```

## Running it

This folder ships only the Dart source + `pubspec.yaml`. The large generated
platform folders (`ios/`, `android/`) are created by Flutter on first setup.

### 1. Install Flutter (if you don't have it)

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$PATH:$HOME/flutter/bin"
flutter --version
```

### 2. Generate platforms + dependencies

```bash
./setup.sh          # runs flutter create + pub get + (iOS) pod install
```

### 3. Run

```bash
flutter devices     # list simulators/devices
flutter run         # build & launch
```

Then drive the app — tap around, browse products, check out, hit the network
buttons — and watch events stream into the portal.

## iOS native SDK — how it's wired (this builds & runs)

The `unitrack` Flutter plugin's iOS pod is **self-contained**: it vendors the
native iOS Swift SDK and the C++ core directly, so there is no separate,
unpublished `UniTrack` pod to resolve. The plumbing:

- `platforms/flutter/ios/sync_native.sh` copies the Swift SDK
  (`platforms/ios/Sources/UniTrack`) and the C++ core (`core/`) into the pod's
  `Native/` directory. CocoaPods only includes sources physically inside the
  pod dir, so this copy is required. `setup.sh` runs it for you.
- `platforms/flutter/ios/Classes/UniTrackPlugin.swift` is a **Swift** bridge
  (the original Obj-C bridge assumed an `@objc` API the Swift SDK doesn't have).
- `ios/Podfile` uses `use_frameworks! :linkage => :static` (required for the
  bundled C++ core).

Fixes applied to the SDK source to make iOS compile:
- `UniTrackURLProtocol.swift`: renamed the private `task` property to `dataTask`
  (it illegally overrode `URLProtocol.task`).
- Flutter plugin iOS bridge rewritten in Swift; plugin podspec made
  self-contained.

If you change the SDK Swift/C++ source, re-run
`platforms/flutter/ios/sync_native.sh` then `cd ios && pod install`.

**Verified**: built for the iOS simulator and confirmed `app_start`,
`app_launched`, and `screen_view` events arriving at the portal in real time.

For **Android**, the Flutter plugin is self-contained: it compiles the local
Android SDK Kotlin sources and builds the C++ core via CMake/NDK directly (no
Maven artifact needed). Just run `flutter run` — the only prerequisite is the
SQLite amalgamation, fetched once with `./scripts/fetch_sqlite.sh`.

## Where events go

Configured in `lib/services/tracking.dart`:

```dart
static const endpoint = 'https://mobix.asia/event-tracking-mobile/v1/events';
```

The portal stores them in SQLite and renders the dashboard at the same base URL.
