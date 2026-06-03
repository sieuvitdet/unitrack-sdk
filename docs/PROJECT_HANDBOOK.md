# UniTrack — Project Handbook

> Tài liệu tổng quan cho người mới (kể cả Claude session mới). Đọc file này là hiểu **what / why / where** của toàn dự án; chi tiết từng phần trỏ ra commit + file cụ thể.

---

## 1. UniTrack là gì

**Một SDK analytics đa nền tảng + portal tự host** dùng chung 1 lõi C++ cho iOS / Android / Flutter / React Native, gửi sự kiện về một backend Node.js (`portal/`) chạy trên VPS (`mobix.asia`). Mục tiêu: thay thế stack đa-nhà-cung-cấp (Snowplow + Firebase + tự build) bằng **một SDK duy nhất** nhưng **fan-out** xuống các provider cũ — đổi nhà cung cấp / format event chỉ cần đổi remote config, không build lại app.

3 đặc tính khác biệt:
- **Auto-capture tận răng**: screen / tap / network / crash / lifecycle / memory_warning — app không cần code track thủ công.
- **Lõi C++ chia sẻ**: 4 binding mỏng, mọi fix ở core đến cả 4 platform miễn phí. Network/queue/retry/crash chỉ implement một lần.
- **Remote config + event rewrite rule**: portal đẩy config xuống app lúc init (endpoint, flags, rename event, schema) → không rebuild app khi đổi taxonomy.

---

## 2. Cấu trúc repo

```
unitrack-sdk/
├── core/                     # C++ core (~1900 LOC) — chia sẻ cho 4 platform
│   ├── include/unitrack/     # public C API (ut_init, ut_track, ut_set_screen, …)
│   ├── src/                  # tracker.cpp, offline_queue.cpp, transport.cpp,
│   │                         #   config.cpp, session_manager.cpp, crash_handler.cpp,
│   │                         #   capi.cpp, event.cpp, logger.cpp, util.cpp
│   └── third_party/sqlite3/  # vendored SQLite (run scripts/fetch_sqlite.sh)
├── platforms/
│   ├── ios/        Swift package — UniTrack.swift + Swizzling/ + Network/UniTrackURLProtocol.swift
│   ├── android/    Gradle :unitrack module — Kotlin + JNI bridge + CMake to core
│   │   └── demo/   "UniTrack Camera Demo" app (5-tab BottomNav)
│   ├── flutter/    Dart plugin — UniTrackNavigatorObserver + auto_capture.dart (taps via Listener)
│   └── react-native/  TS plugin — createNavigationTracker + UniTrackTapBoundary + fetch interceptor
├── ios-camera-demo/          # SPM consumer of the iOS package (the gold-standard demo)
├── react-native-demo/        # Mirrors the camera demo on RN
├── portal/                   # Node.js backend + SPA (Express, node:sqlite, vanilla JS)
│   ├── server.js api.js ingest.js agent.js agent_scheduler.js deliver.js
│   ├── config.js db.js auth.js scoring.js snowplow.js telegram_bot.js
│   └── public/index.html     # the entire SPA (~2700 LOC)
└── docs/                     # ← this folder
    ├── PROJECT_HANDBOOK.md   # this file
    └── slides/               # 10 slides telling the UniTrack story
```

Notes:
- Lõi C++ **vendored** vào iOS Swift Package + Flutter plugin via `platforms/ios/sync_core.sh` + `platforms/flutter/ios/sync_native.sh` + `UniTrackSwiftPackage/scripts/sync_core.sh` (Swift Package repo riêng). **Sau khi sửa `core/src/*`, chạy scripts rồi commit cả 2 repo.**
- Android `:unitrack` build core trực tiếp từ `../../../../../../core/src` qua CMake — không cần vendor.
- React Native plugin Android depend `io.unitrack:sdk` (Maven). Để test core fix với RN local: `./gradlew :unitrack:publishToMavenLocal` + `mavenLocal()` trong demo's repo.

---

## 3. Luồng dữ liệu end-to-end

```
   App (iOS / Android / Flutter / RN)
        │
        │ auto-capture (swizzle / observer / fetch wrap)
        ▼
   Binding (Swift / Kotlin / Dart / TS) — thin shim
        │
        │ FFI / JNI / MethodChannel / native module
        ▼
   C++ core (Tracker)
        │   • enqueue → OfflineQueue (SQLite WAL on app's files dir)
        │   • worker thread: batch + flush (flush_interval_ms or background)
        ▼
   HTTP transport callback installed by binding
        │   iOS: HTTPBridge.swift (URLSession + URLProtocol)
        │   Android: NativeBridge.httpPost via JNI bounce (HttpURLConnection)
        │   Flutter: Android NativeBridge / iOS HTTPBridge (shared with native)
        │   RN: same Android/iOS bridges (RN module is a thin wrapper on core)
        ▼
   POST https://mobix.asia/event-tracking-mobile/v1/events
        │   JSON array body — bare [{event}, {event}, ...]
        │   Authorization: Bearer <api_key>
        ▼
   portal/ingest.js
        │   • validate (isValid) → reject bad timestamp / event_name
        │   • normalize → events table (project_id resolved from api_key)
        │   • optional: forward to Snowplow collector (mapped events)
        ▼
   SQLite (node:sqlite, WAL) — events / app_sessions / projects / agent_config
        │
        ▼
   portal/agent.js
        │   • reconstructSessions(projectId) — rebuilds app_sessions from raw events
        │   • computeFlows + computeFlowGraph — flow signature, heatmap, dwell, stuck
        │   • runCycle → LLM analyze → LLM report → deliver()
        ▼
   Portal SPA (public/index.html)  +  Telegram bot (telegram_bot.js)
```

---

## 4. Auto-capture per platform — what does what

| Capture | iOS | Android | Flutter | React Native |
|---|---|---|---|---|
| `screen_view` | `ViewControllerSwizzler` viewDidAppear → class name (module prefix stripped) | `ActivityTracker` onActivityResumed + Fragment lifecycle → class.simpleName | `UniTrackNavigatorObserver` didPush/Pop → `route.settings.name ?? runtimeType` | `createNavigationTracker` onStateChange → React Navigation route name |
| `screen_start` / `screen_end` + `dwell_ms` | emitted by core when `set_screen` changes (renameable via remote config) | same | same | same |
| `tap` element_key | `ControlSwizzler` swizzles `UIApplication.sendAction` → accessibilityIdentifier > title | `ClickTracker` window callback → view.tag > resource entry name > contentDescription > text | `auto_capture.dart` Listener → Semantics > text > tooltip > Key > icon | `UniTrackTapBoundary` fiber walk → testID > accessibilityLabel > component name |
| `network_request` | `UniTrackURLProtocol` (URLProtocol registered globally) | `OkHttpTracker.attach(client)` (interceptor — must be wired manually) | `HttpOverrides.global` wraps `dart:io` HttpClient | global `fetch` monkey-patch |
| `app_start / foreground / background` | `AppLifecycleObserver` (UIApplication notifications) | `AppLifecycleObserver` (lifecycle callbacks) | reuses Android/iOS native via plugin | reuses Android/iOS native |
| `session_start / session_end` | core `SessionManager` with timeout-based rotation | same (core) | same | same |
| `crash` | native C++ crash handler (`crash_handler.cpp` — signal handlers, JSON on disk, flushed next launch) | same + Kotlin `UncaughtExceptionHandler` (demo) | same + Dart `FlutterError.onError` (app-level) | same + JS `ErrorUtils.setGlobalHandler` (app-level) |
| `memory_warning` | iOS doesn't surface easily (TODO) | `onTrimMemory` → core | same | same |

---

## 5. Portal — what each tab shows

Open `https://mobix.asia/event-tracking-mobile/`, sign in (admin@mobix.asia), click a project.

| Tab | What it shows |
|---|---|
| **Log events** | Raw event stream, filter by screen / event / provider. Read-only firehose. |
| **Sessions** | Reconstructed user sessions. **User filter dropdown.** Click a session → IDE-style overlay: left = session list, middle = vertical timeline (reversed, newest on top, animated `▲` arrow connectors), right = per-screen detail (actions + nested network chip). Search box matches across class names, labels, element keys, API URLs, statuses. **Crash count badge** at top — click to filter to buggy screens only. |
| **Hành trình & Heatmap** | Two modes: **Flow** = aggregate screen graph (stuck score colour, edges between screens); **Heatmap** = same graph but node size/colour = engagement (visits + events + taps), right sidebar lists most-tapped buttons. User-filterable. **Fullscreen + pan/zoom**. Click a session in the sidebar to draw its journey as a separate green overlay on top of the aggregate graph + replay bar (always visible at the bottom with Play / seek / speed 0.25x–8x). |
| **Agent** | Per-project agent_config (LLM endpoint, prompts, Telegram bot, schedule). One-shot "Run now" + history of agent_reports. |
| **Cây class → event** | Class-to-event-name mapping (event_mappings) — drag-and-drop the raw `element_key` of taps onto a declared `event_def` to convert ad-hoc taps into named business events. |
| **Config (remote)** | Editor for the JSON the app pulls at startup — endpoint, batch_size, flush_interval, trackScreens/Taps/Network, Snowplow & Firebase blocks, **screen_lifecycle + screen_start_event + screen_end_event (renameable taxonomy)**, event rewrite rules. Bumps version → app re-downloads next launch. |

There's also a per-project header bar with:
- **⚙ Providers** — toggle Snowplow / Firebase forwarding, paste Snowplow forward URL, drag-drop `google-services.json` / `GoogleService-Info.plist`.
- **🏷 Tên màn** — paste a JSON map (e.g. `{"HomeScreen":"Trang chủ"}`) to friendlify everything in the portal **and** make screen names searchable in Vietnamese.

---

## 6. Key files to know (when something breaks)

| Symptom | Look here |
|---|---|
| Events don't arrive on Android | `platforms/android/unitrack/src/main/java/com/unitrack/sdk/bridge/NativeBridge.kt` — `httpPost`, JNI lookup. `core/src/transport.cpp` — `send_builtin` "no HTTP callback" fallback. |
| Release build crashes on launch with `NoSuchMethodError` | R8 stripped the JNI-called method. Check `@Keep` on `NativeBridge` (Kotlin) + `consumer-rules.pro` shipped by `platforms/flutter/android/`. |
| screen_view doubled (e.g. `MyApp.HomeVC` + `HomeVC`) | iOS Snowplow auto-tracking on. Set `screenViewAutotracking:false` in `SnowplowOptions` (default false now). `platforms/ios/Providers/UniTrackSnowplow/Sources/SnowplowProvider.swift`. |
| Tap captures only `_UIButtonBarButton#__backButtonAction:` | iOS `ControlSwizzler` was swizzling `UIControl.sendAction` (UIAction-based buttons bypass it). Now swizzles `UIApplication.sendAction` — see `platforms/ios/Sources/UniTrack/Swizzling/ControlSwizzler.swift`. |
| Tap fires `UnsatisfiedLinkError` on RN | RN navigation tracker fires `setScreen` before `UniTrack.initialize` finishes (async). `UniTrack.kt` guards every native call behind `if(initialized)`; `initialized` is set BEFORE installing auto-capture (so the install-time setScreen doesn't get dropped). |
| Network flooded with image thumbnails | `agent.js` filters media URLs (`view-file`, `*.png/.jpg/.gif/…`) from the reconstructed journey. Adjust `MEDIA_URL_RE` if needed. |
| Wrapper / container routes double-count on Flutter | `UniTrackNavigatorObserver` has `skipRoutePatterns` (default `WrapperPageRoute$`) + `coalesceWindow`. For app-side observers (`ModuleNavigatorObserver.onScreenView`), filter inside `UniTrackService.trackScreen` too — see MobiX `unitrack_service.dart`. |

---

## 7. Build / test / deploy quick reference

```bash
# === Core C++ host tests (macOS / Linux) ===
./scripts/fetch_sqlite.sh                       # once
cmake -S core -B build/host -DUT_USE_BUNDLED_SQLITE=ON
cmake --build build/host -j
./build/host/tests/unitrack_tests               # all unit tests (~64 cases)

# === Android camera demo ===
cd platforms/android
./gradlew :demo:assembleDebug
# APK at: platforms/android/demo/build/outputs/apk/debug/demo-debug.apk
./gradlew :unitrack:publishToMavenLocal         # for RN demo to pick up local SDK

# === iOS camera demo ===
cd ios-camera-demo
DEV_TEAM=7755R4CX4U ruby gen_project.rb         # signs with your Apple Dev team
open UniTrackCameraDemo.xcworkspace             # build + run from Xcode

# === React Native camera demo ===
cd react-native-demo && npm install
cd android && ./gradlew :app:assembleDebug
# Debug APK needs Metro — start: `npx react-native start` + `adb reverse tcp:8081 tcp:8081`

# === Portal (local dev) ===
cd portal && npm install && node server.js      # :8080 by default
# DB path = ./portal/data.db (SQLite, WAL)

# === Portal deploy (production VPS) ===
# scp public/index.html  → root@mobix.asia:/root/event-tracking-portal/public/
# scp *.js               → root@mobix.asia:/root/event-tracking-portal/
# ssh mobix.asia "pm2 restart event-tracking-portal"
```

---

## 8. Project IDs on the portal (mobix.asia)

| pid | Name | source_type | Used for |
|---|---|---|---|
| 3 | camera | native_ios | iOS camera demo (gold standard) |
| 4 | MobiX | flutter | Real MobiX staging app — the live test case |
| 5 | Demo Android | native_android | Android camera demo |
| 6 | Demo React Native | react-native | RN camera demo |

Each has its own api_key; keys are stored hardcoded in the respective demo. MobiX's api_key (`utk_FCpTmA8yVVEE7_hxH9vePhMw`) lives in `MobinetNexgenNew/lib/core/middleware/unitrack_service.dart`.

---

## 9. Conventions that matter

1. **Don't auto-commit MobiX** (`/Volumes/DucsM1/MobinetNexgenNew`). It's a production repo — leave changes in the working tree for the user to review.
2. **iOS Swift fixes go in TWO repos**: monorepo `platforms/ios/` AND the SwiftPM repo at `/Volumes/DucsM1/unitrack-sdk/UniTrackSwiftPackage/` (remote `sieuvitdet/unitrack-ios-package`). Core is auto-synced via `sync_core.sh`; Swift sources must be copied manually.
3. **`@Keep` on anything JNI / Reflection calls by name**. R8 will rename otherwise. Same for proguard `-keep` rules in `consumer-rules.pro` shipped with binding modules.
4. **Telegram messages: plain text only.** Markdown parse fails on `_` / `*` in user_ids and element_keys ("can't find end of entity").
5. **`mavenLocal()` for RN local dev**: RN's Android module depends on `io.unitrack:sdk` (Maven artifact). To test a core fix with RN before publishing, `publishToMavenLocal` + add `mavenLocal()` in the RN demo's `android/build.gradle`.
6. **`scripts/fetch_sqlite.sh` is mandatory** before the first Android / iOS native build — downloads the SQLite amalgamation the C++ core links.

---

## 10. Stuff that's intentionally left as TODO / future work

- iOS `memory_warning` capture (low priority — iOS surfaces this differently than Android `onTrimMemory`).
- Body capture is opt-in (`UniTrackBodyCapture`) — production should consider masking sensitive fields.
- React Native module depends on Maven artifact; ideally switch to source-link like the Flutter plugin for symmetry.
- Auto-route `auto_route` integration could ship a custom skip pattern as a default for Dart consumers.
- `set_screen` doesn't emit `screen_end` for the **last screen** when the app exits (we'd need a flush boundary on session_end — currently the portal can compute it from session_end timestamp).

---

## 11. How to onboard a new Claude session in 30 seconds

1. `git log --oneline -20` — see recent commits, each tells a story (fix titles are self-explanatory).
2. `cat docs/PROJECT_HANDBOOK.md` (this file).
3. `cat ~/.claude/projects/-Volumes-DucsM1-unitrack-sdk-unitrack-sdk/memory/MEMORY.md` — auto-loaded memory index points at fix histories.
4. Ask the user: **which platform? which symptom?** Then jump to "Key files to know" in §6.
