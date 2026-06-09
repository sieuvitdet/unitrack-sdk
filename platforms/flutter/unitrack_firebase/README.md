# unitrack_firebase

Firebase provider for [UniTrack](https://pub.dev/packages/unitrack). Forwards
UniTrack events to Firebase Analytics and bundles optional helpers for FCM
(token + push notifications), Crashlytics (non-fatal errors), and Remote
Config (resolver chain).

## Install

```yaml
dependencies:
  unitrack: ^1.0.0
  unitrack_firebase: ^1.0.0
```

You also need the standard FlutterFire setup:

- Android — `android/app/google-services.json` + the `google-services` Gradle
  plugin.
- iOS — `ios/Runner/GoogleService-Info.plist` added to the Runner target.

## Wire-up Analytics

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:unitrack/unitrack.dart';
import 'package:unitrack_firebase/unitrack_firebase.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  UniTrack.instance.addProvider(FirebaseProvider(
    superProperties: {'app_segment': 'consumer'},
    userProperties:  {'cohort': 'gold'},
  ));
  await UniTrack.instance.initialize('utk_your_api_key');
  runApp(const MyApp());
}
```

`FirebaseProvider` sanitises event + parameter names (Firebase requires
alphanumeric + underscore, ≤ 40 chars), coerces non-primitive values to
strings, and clamps string params to 100 chars. Anything else passes through
untouched.

## Messaging (FCM) helper

Wire UniTrack into your existing FCM callbacks — no swizzling, just one call
per site:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:unitrack_firebase/firebase_messaging_helper.dart';

void wireFcm() {
  FirebaseMessaging.instance.onTokenRefresh
      .listen(UniTrackFirebaseMessaging.handleTokenUpdate);

  FirebaseMessaging.onMessage
      .listen(UniTrackFirebaseMessaging.handleNotificationReceivedForeground);

  FirebaseMessaging.onMessageOpenedApp
      .listen(UniTrackFirebaseMessaging.handleNotificationClicked);
}
```

Result: `fcm_token_updated` + `notification` events flow through UniTrack →
portal + Snowplow + Firebase Analytics.

## Crashlytics helper

```dart
import 'package:unitrack_firebase/firebase_crashlytics_helper.dart';

try {
  await riskyCall();
} catch (e, st) {
  await UniTrackFirebaseCrashlytics.recordError(e, st);
}

UniTrackFirebaseCrashlytics.log('entering checkout flow');
UniTrackFirebaseCrashlytics.setCustomKey('cart_size', 3);
```

`recordError` does both: full symbolicated stack to Crashlytics, plus an
`application_error` event through UniTrack so the portal sees it too.

## Remote Config

Plug Firebase RC into UniTrack's unified resolver. Order:

1. Portal `sdk_config.custom_values[key]`
2. Firebase Remote Config (via this helper)
3. Caller's `defaultValue`

```dart
import 'package:unitrack_firebase/firebase_remote_config_helper.dart';

await UniTrackFirebaseRemoteConfig.activate(
  defaults: {'feature_camera_grid': false, 'home_banner_copy': 'Welcome'},
  minimumFetchInterval: const Duration(hours: 1),
);

final on  = await UniTrack.instance.getRemoteValue<bool>(
  'feature_camera_grid', defaultValue: false);
final txt = await UniTrack.instance.getRemoteValue<String>(
  'home_banner_copy', defaultValue: '');
```

## License

MIT — see [LICENSE](LICENSE).
