# UniTrack UIKit Demo (native iOS)

A plain **UIKit** app that proves the SDK's *native auto-capture*. The only
tracking code in the entire app is one `UniTrack.initialize(...)` call in
`AppDelegate.swift`. Every screen and button below contains **zero** tracking
code — yet taps, screen views, network calls, lifecycle and crashes are all
captured automatically.

This is the contrast to Flutter: here the UI is real UIKit (`UIButton`,
`UIViewController`), which is exactly what the SDK's swizzlers hook — so the SDK
*can* see which button on which screen was tapped, with no per-widget code.

## What's auto-captured (no code)

| Event | How | Where it comes from |
|---|---|---|
| `screen_view` | `UIViewController.viewDidAppear` swizzle | every VC appearance (Home, Sản phẩm, detail) |
| `tap` | `UIControl.sendAction` swizzle | every `UIButton` tap, keyed by `accessibilityIdentifier` → `restorationIdentifier` → button title → class |
| `network_request` | `URLProtocol` interception | the "Gọi API" buttons |
| `app_foreground` / `app_background` | `UIApplication` lifecycle | backgrounding the app |
| `app_start` | C++ core cold-start metric | launch |
| `crash` | POSIX signal handler | (if the app crashes) |

The buttons demonstrate element-key resolution:
- `home_open_products`, `home_call_api_ok`, `home_call_api_404`,
  `detail_add_to_cart` have explicit `accessibilityIdentifier`s → those are the
  tap keys.
- "Nút không có ID" has **no** identifier → the SDK falls back to its title.

Events go to **https://mobix.asia/event-tracking-mobile** — open it in a browser
to watch them arrive live.

## Run it

```bash
# 1. Generate the Xcode project (consumes the SDK via local Swift Package).
ruby gen_project.rb          # needs the `xcodeproj` gem (gem install xcodeproj)

# 2. Open and run on a simulator.
open UniTrackUIKitDemo.xcodeproj
#   → pick an iPhone simulator, press ⌘R, then tap around.

# …or build/run from the CLI:
xcodebuild -project UniTrackUIKitDemo.xcodeproj -scheme UniTrackUIKitDemo \
  -sdk iphonesimulator -configuration Debug -derivedDataPath build build
```

Then tap the buttons, push into product screens, send the app to the
background — and watch `tap` / `screen_view` / `network_request` events appear
on the portal, none of which you wrote tracking code for.

## SDK fixes this demo required (applied to `../platforms/ios`)

Wiring the SDK into a clean SPM build surfaced real gaps in the SDK's package,
now fixed:

1. **`Package.swift`** had a `testTarget` pointing at a non-existent
   `Tests/UniTrackTests` → removed (it broke SPM resolution).
2. **`UniTrackCore`** target shipped headers only — the C++ implementation in
   `core/src` was never compiled. Symlinked `core/src` into the target and
   taught `Package.swift` to compile it (`c++17`, header search paths) and link
   `sqlite3`.
3. **`UniTrack.swift` / `HTTPBridge.swift`** never imported the C module;
   added a guarded `#if canImport(UniTrackCore) import UniTrackCore #endif`
   (the guard keeps the CocoaPods/Flutter single-module build working too).

With these, `UniTrack` builds cleanly as a Swift Package and as a CocoaPod.
