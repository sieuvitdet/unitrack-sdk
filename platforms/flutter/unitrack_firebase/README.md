# unitrack_firebase

Firebase Analytics provider for [UniTrack](../). Forwards **every** UniTrack
event to Firebase Analytics. The core `unitrack` package has no Firebase
dependency — add this package only when you want Firebase forwarding.

## Install

```yaml
dependencies:
  unitrack:
    path: ../platforms/flutter
  unitrack_firebase:
    path: ../platforms/flutter/unitrack_firebase
```

## Firebase project files (standard FlutterFire setup)

This package only calls `Firebase.initializeApp()` + `logEvent`; you supply the
project credentials the normal way:

- **Android**: put `google-services.json` in `android/app/`, and apply the
  plugin:
  - `android/build.gradle` (buildscript): `classpath 'com.google.gms:google-services:4.4.x'`
  - `android/app/build.gradle`: `apply plugin: 'com.google.gms.google-services'`
- **iOS**: add `GoogleService-Info.plist` to `ios/Runner/` and to the Runner
  target's *Copy Bundle Resources* build phase (Xcode).

(Or run `flutterfire configure` to generate `firebase_options.dart` — then pass
those options if you prefer; the default `Firebase.initializeApp()` reads the
platform files above.)

## Use

```dart
import 'package:unitrack/unitrack.dart';
import 'package:unitrack_firebase/unitrack_firebase.dart';

UniTrack.instance.addProvider(FirebaseProvider());
await UniTrack.instance.initialize(apiKey);
```

- UniTrack events → `FirebaseAnalytics.logEvent(name, parameters)`.
- Event/param names are sanitized to Firebase rules (≤40 chars, alphanumeric +
  `_`, must start with a letter); a debug warning is logged when a name changes.
- `setScreen()` → `logScreenView`; `identify()` → `setUserId` + user properties.
