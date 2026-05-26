# Mobix UniTrack — React Native Demo

A bare React Native (CLI) app that integrates the UniTrack SDK. **All tracking
is declared once in `App.tsx`; the screens contain zero tracking code.**

> Events go to **https://mobix.asia/event-tracking-mobile** — open it in a
> browser to watch them arrive live.

## What's auto-captured (no per-screen / per-button code)

| Event | How |
|---|---|
| `screen_view` | `createNavigationTracker()` on the NavigationContainer |
| `tap` | `<UniTrackTapBoundary>` wraps the app; resolves the button name from `testID` → `accessibilityLabel` → text → component |
| `network_request` | the SDK's global `fetch` interceptor, with `triggered_by_element` + `triggered_by_screen` mirrored from the last tap |
| `crash` | global JS error handler in `App.tsx` (a JS `throw` is not a native signal, so it's hooked in JS) |
| app foreground/background, memory, native crash | the native iOS/Android SDK underneath |

Buttons with a `testID` (e.g. `home_open_products`, `detail_add_to_cart`) report
that as the tap name. The "Nút không có ID" button has none → the SDK falls back
to its text label.

## Why tap capture is in JS (like Flutter is in Dart)

React Native maps components to real native views, so the native tap swizzlers
*do* fire — but they only see the native view class, not your JS component or
`testID`. To get a meaningful button name, `UniTrackTapBoundary` observes touches
in JS (capture phase) and walks the React Fiber tree of whatever was tapped.

## Run it

This project was created with `--skip-install`, so install first:

```bash
cd react-native-demo
npm install --legacy-peer-deps          # SDK is a local file: dependency

# iOS
cd ios && pod install && cd ..
npx react-native run-ios

# Android (emulator running or device connected)
npx react-native run-android
```

Then tap around and watch `tap` / `screen_view` / `network_request` / `crash`
events appear on the portal — none of which you wrote tracking code for.

> The `@unitrack/react-native` dependency points at `../platforms/react-native`
> via `file:`. If you change the SDK, re-run `npm install --legacy-peer-deps`.
