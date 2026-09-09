# RN Cross-Binary Test Bed

Verify `unitrack-react-native@1.2.0` khi native host **đã link `UniTrack` riêng**
(SPM iOS / JitPack Android). Kịch bản = "native app đã có UniTrack, giờ nhúng
thêm 1 RN screen". Mục tiêu: **1 process = 1 UniTrack singleton = 1 session_id**.

Không dùng `npx react-native init` — thay vì đó anh giữ folder tối giản,
chỉ ~4 file per platform để dễ audit.

## Cấu trúc

```
example-cross-binary/
├── rn/                          # JS layer chạy trong RCTBridge của host
│   ├── App.tsx                  # 3 button test
│   ├── index.js
│   └── package.json             # depend `unitrack-react-native` local
├── ios/                         # native Swift host + Podfile
│   ├── Podfile
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   └── project.yml              # XcodeGen spec
├── android/                     # native Kotlin host
│   ├── app/build.gradle.kts
│   ├── app/src/main/AndroidManifest.xml
│   ├── app/src/main/java/com/example/host/MainApplication.kt
│   ├── app/src/main/java/com/example/host/MainActivity.kt
│   ├── build.gradle.kts
│   ├── settings.gradle.kts
│   └── gradle.properties        # unitrack.skipVendor=true
└── README.md                    # bro đang đọc
```

## Test scenarios

Mỗi button trong `App.tsx` xác thực 1 tính chất:

| # | Button                    | Kỳ vọng                                                                            |
|---|---------------------------|------------------------------------------------------------------------------------|
| 1 | `track('rn_button')`      | Chỉ 1 event trong `pendingEventCounts()` của native — không double-emit            |
| 2 | `customTrack('...')`      | Native log `customTrack payload` với `session_id == native.currentSessionId()`     |
| 3 | `getSessionId()` (JS)     | Match value host app đã in ra ở AppDelegate/MainApplication khi `initialize()`     |

Session_id giống nhau = HostProxy resolve về native singleton, không có 2
SQLite queue riêng.

## Run iOS

```sh
# 1. Build RN JS bundle offline (dev mode dùng metro bundler sẽ nói dưới)
cd rn && npm install && cd ..

# 2. Sinh Xcode project + install pod
brew install xcodegen
cd ios
xcodegen generate
pod install
open UniTrackRNHost.xcworkspace
```

Chạy trên simulator iOS 16+. Console log filter `[UniTrack]` — anh cần thấy:

```
[UniTrackPlugin] host detected: co-resident mode
[UniTrack/RN] co-resident: skip RN init, piggyback native singleton
[UniTrack] initialized apiKey=utk_test session_id=<UUID_A>
[UniTrack] track name=rn_button session_id=<UUID_A>   ← cùng UUID_A
```

## Run Android

```sh
cd rn && npm install && cd ..
cd android
./gradlew :app:installDebug
adb shell am start -n com.example.host/.MainActivity
adb logcat -s UniTrack UniTrackRN
```

Log expected:

```
UniTrackRN: skipVendor=true — host phải supply com.github.sieuvitdet:unitrack-sdk
UniTrack: initialize session_id=<UUID_B>
UniTrack: customTrack rn_button session_id=<UUID_B>   ← cùng UUID_B
```

## Metro bundler (dev mode)

Trong khi test có thể dùng bundled JS (đã bake vào app) hoặc metro live:

```sh
cd rn
npx react-native start --port 8081
```

Rồi trong host app trỏ `RCTBundleURLProvider.jsBundleURL(forBundleRoot: "index")`.
Bundled offline (Release) không cần metro.

## Nếu Podfile fail

Podfile trỏ:
- `RNUniTrack` = pod local file `../../../react-native/RNUniTrack.podspec`
- `UniTrack` = SPM package local file `../../../ios/`

Cả 2 point về monorepo, KHÔNG cần publish npm/pod trước. Debug lỗi build:

```sh
pod install --verbose 2>&1 | tee /tmp/pod.log
```

## Test skipVendor guard (Android)

Toggle `unitrack.skipVendor=false` trong `android/gradle.properties` → build phải
fail với duplicate class `com.unitrack.sdk.UniTrack` (vì host app + RN plugin
cùng pull JitPack). Confirm rule "skipVendor bắt buộc khi co-resident".

Sau khi verify, đặt lại `true`.
