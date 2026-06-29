# Changelog

All notable changes to UniTrack SDK are documented here.

## [Unreleased]

### Added

- iOS HostProxy parity for the React Native plugin so the RN-iOS and native iOS
  SDKs share a single in-process singleton (same `session_id`, same provider
  list) when both are linked into one app (commit `0ed21bf`).
- Flutter `UniTrackHttpClient` — a Dart `http.Client` wrapper that injects
  `traceparent`, logs the round-trip via the C core, and surfaces errors as
  `network_error` events (commit `0cad398`).

### Changed

- Flutter Android plugin is now **self-contained**: the C++ core and bundled
  SQLite are vendored into the plugin's CMake build, so apps no longer need
  the monorepo on disk to compile the Android side (commit `2e9d491`).

### Documentation

- FPT Life integration guide for iOS, Android, and the embedded Flutter module
  (`docs/fpt-life-flutter-integration.md`, `docs/fpt-life-integration.md`).
- Cross-binary integration matrix (`docs/cross-binary-integration.md`)
  covering the four Native ⨯ Flutter / RN combinations.
- Portal config realtime-vs-reinit matrix
  (`docs/portal-config-realtime-matrix.html`).

## [1.2.0] — 2026-06

Aggregate of feature work shipped across the four platforms since 1.0.0. The
SDK family was bumped to **1.2.x** to match Flutter (already at 1.2.1) and
keep one cross-platform line in changelogs and docs.

### Added

- **Cross-language layer registry + screen dedup** (core + iOS + Flutter).
  Native swizzler and Dart route observer announce themselves to the C core
  via a shared bitmask. When user navigates Native → Flutter, only one
  `screen_view` event reaches the backend — the Dart subtree claim wins
  inside a 250 ms dedup window (commit `60ef2f3`).
- **Cross-binary singleton sharing** (iOS + Flutter). The Flutter plugin
  detects a co-resident host iOS SDK via `UniTrackHostProxy` and forwards
  `track`, `setUser`, `screen`, and `registerLayer` to it instead of running
  a parallel C core. Same `session_id`, same provider list, no double-send
  (commit `c9c7910`).
- **Kill detection** in the C core. Cold start now fires a delayed
  `session_ended` for the previous session as soon as it can tell the prior
  process did not exit cleanly (commit `90eb20a`).
- **Manual tracking priority** on iOS — when the app calls `UniTrack.track`
  for an event the auto-capture pipeline would also emit, the auto event is
  skipped to avoid duplicates (commit `f714729`).
- **WebView capture** across all four platforms. The injected JS now reads
  `data-sp-*` attributes and the page `<title>`, so taps on web content get
  the same element-key fidelity as native UI (commit `88e8c85`).
- **FirebaseAdapter `setDefaultEventParameters`** for `session_id`
  (iOS + Android + RN + Flutter). Events fired directly through Firebase
  Analytics — including Firebase's own auto-events — now carry the current
  UniTrack `session_id` (commits `65fbc94`, `6e6b9f2`).
- **Phase 6 Provider Adapter** with per-provider ack queue, built-in
  `HttpProvider`, and `FirebaseAdapter` reflection so the SDK can stamp
  Firebase Analytics without a hard `firebase-ios-sdk` dependency
  (commits `3cc61ff`, `4a5caec`).
- **Portal realtime config** via SSE stream + foreground re-fetch throttle.
  `start(remote:)` now reruns `removeAllProviders` + `addProvider` so most
  Portal-side edits (Snowplow `appId`, `endpoint`, event-name map, Firebase
  on/off, tracing hosts) are picked up in < 1 s on iOS, < 5 min on the rest
  (commits `1cda3f6`, `2a9d870`).
- **`UniTrack.applyHotConfig`** for hot-reloading the screen-event name
  triplet (`screen_start_event`, `screen_end_event`, `screen_load_event`)
  without restarting the swizzler (commit `cbf0979`).
- **Portal session-detail UI** — full-width flat event list with 3 s
  auto-refresh live-tail (commits `e2caeec`, `f8b7843`).

### Changed

- **`session_id` is now the only join key** between SDK and Portal —
  `tracking_id` removed end-to-end (commit `5b09297`).
- Snowplow / Firebase fan-out now reaches `screen_viewed` / `screen_exited`
  events too, not just `track` (commit `fc436d8`).
- iOS dropped the standalone `UniTrackFirebase` SPM target — the built-in
  reflection-based `FirebaseAdapter` replaces it (commit `5724356`).

### Fixed

- iOS `UniTrackConfigStream.ingest` crash when an SSE chunk landed on a
  unicode boundary (`String.Index` out-of-bounds) (commit `2dd044c`).
- iOS `GestureRecognizerSwizzler` no longer pokes the private `_targets`
  KVC backdoor — gone, App Store rejection risk gone (commit `87cca79`).

### Removed

- Firebase helper packages (`@unitrack/firebase`, `unitrack_firebase`,
  `platforms/android/unitrack-firebase`) fully removed (commit `677a999`).
  Firebase Analytics mirror is now built into the core `FirebaseAdapter`
  (reflection-based) — apps wire Firebase modules directly with no SDK shim.

### Per-package versions

| Package | Version |
| --- | --- |
| `unitrack-sdk` (this repo, aggregate)  | `1.2.0` |
| iOS (CocoaPods `UniTrack`)             | `1.0.0` (podspec — published as `0.3.x` on JitPack during dev) |
| Android (Maven `com.unitrack.sdk:unitrack`) | `1.0.0` (Maven — `0.3.37` on JitPack) |
| `@unitrack/react-native` (npm)         | `1.1.0` |
| `unitrack` (pub.dev — Flutter)         | `1.2.2` |
| `unitrack_snowplow` (pub.dev)          | `1.1.0` |

> Firebase Analytics mirror đã built-in vào FirebaseAdapter (reflection-based) —
> các module helper `@unitrack/firebase`, `unitrack_firebase`,
> `platforms/android/unitrack-firebase` đã được gỡ (commit `677a999`).

## [1.0.0] — 2026-05-21

### Added
- C++ shared core (`libunitrack`)
  - Event pipeline with sampling and batching
  - SQLite-backed persistent offline queue
  - HTTP transport with optional libcurl backend and platform-injectable callback
  - Session manager with timeout-based rotation
  - POSIX signal-based crash handler with async-signal-safe trace capture
- iOS framework
  - `UIViewController` swizzling for automatic screen tracking
  - `UIControl.sendAction` swizzling for automatic tap tracking
  - `URLProtocol` subclass for URLSession network interception
  - `UIApplication` memory warning observer
  - `UIApplicationDelegate` lifecycle observer
  - Public Swift API: `UniTrack.initialize`, `track`, `identify`, `setScreen`
  - `UniTrackDecoder` safe JSON wrapper
  - Swift Package Manager and CocoaPods support
- Android library
  - `ActivityLifecycleCallbacks` for screen tracking + Fragment lifecycle
  - `Window.Callback` wrap for tap tracking
  - OkHttp `Interceptor` for network tracking
  - `ComponentCallbacks2` memory pressure handling
  - JNI bridge to the C++ core
  - `UniTrackJson` safe parse wrapper
  - Maven publication
- React Native module
  - TypeScript public API with platform module bridges (iOS + Android)
  - Global `fetch` interceptor
  - React Navigation tracker
  - `safeJsonParse` helper
- Flutter plugin
  - Dart public API via `MethodChannel`
  - iOS and Android plugin code
  - `UniTrackNavigatorObserver` for route tracking
  - `safeJsonParse` helper
- Reference ingest backend (Node.js + Express + SQLite)
- Test suite
  - Host-machine unit tests for core (see `tests/core_tests.cpp`)
  - End-to-end integration test (SDK → HTTP → backend → SDK)
  - Android instrumented tests
- Build scripts (`fetch_sqlite`, `build_ios`, `build_android`, `build_rn`,
  `build_flutter`, `release`)
- GitHub Actions CI matrix
