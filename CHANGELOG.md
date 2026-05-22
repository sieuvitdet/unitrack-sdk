# Changelog

All notable changes to UniTrack SDK are documented here.

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
  - 31 host-machine unit tests for core
  - End-to-end integration test (SDK → HTTP → backend → SDK)
  - Android instrumented tests
- Build scripts (`fetch_sqlite`, `build_ios`, `build_android`, `build_rn`,
  `build_flutter`, `release`)
- GitHub Actions CI matrix
