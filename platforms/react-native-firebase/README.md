# @unitrack/firebase

Firebase provider for [@unitrack/react-native](https://www.npmjs.com/package/@unitrack/react-native).
Forwards UniTrack events to Firebase Analytics and bundles optional helpers for
FCM (token + push), Crashlytics (non-fatal errors), and Remote Config.

## Install

```bash
npm install @unitrack/firebase \
  @react-native-firebase/app @react-native-firebase/analytics
# Optional, only install what you use:
npm install @react-native-firebase/messaging \
            @react-native-firebase/crashlytics \
            @react-native-firebase/remote-config
cd ios && pod install
```

You also need the standard `@react-native-firebase` setup:

- Android: `android/app/google-services.json` + `com.google.gms.google-services` Gradle plugin.
- iOS: `ios/<App>/GoogleService-Info.plist` added to the Runner target.

## Wire Analytics

```ts
import { UniTrack } from '@unitrack/react-native';
import { FirebaseProvider } from '@unitrack/firebase';

UniTrack.addProvider(new FirebaseProvider());
await UniTrack.initialize('utk_your_api_key');
```

## FCM Messaging helper

```ts
import messaging from '@react-native-firebase/messaging';
import { UniTrackFirebaseMessaging } from '@unitrack/firebase';

messaging().onTokenRefresh(UniTrackFirebaseMessaging.handleTokenUpdate);
messaging().onMessage(UniTrackFirebaseMessaging.handleNotificationReceivedForeground);
messaging().onNotificationOpenedApp(UniTrackFirebaseMessaging.handleNotificationClicked);

const initial = await messaging().getInitialMessage();
if (initial) UniTrackFirebaseMessaging.handleNotificationClicked(initial);
```

Result: `fcm_token_updated` + `notification` events flow through UniTrack →
portal + Snowplow + Firebase Analytics.

## Crashlytics helper

```ts
import { UniTrackFirebaseCrashlytics } from '@unitrack/firebase';

try { await riskyCall(); }
catch (e) { await UniTrackFirebaseCrashlytics.recordError(e); }

UniTrackFirebaseCrashlytics.log('entering checkout flow');
await UniTrackFirebaseCrashlytics.setCustomKey('cart_size', 3);
```

`recordError` does both: symbolicated stack to Crashlytics, plus an
`application_error` event through UniTrack so the portal sees the same incident.

## Remote Config

Plug Firebase RC into UniTrack's unified resolver. Order:

1. Portal `sdk_config.custom_values[key]`
2. Firebase Remote Config
3. Caller's defaultValue

```ts
import { UniTrack } from '@unitrack/react-native';
import { UniTrackFirebaseRemoteConfig } from '@unitrack/firebase';

await UniTrackFirebaseRemoteConfig.activate({
  defaults: { feature_camera_grid: false, home_banner_copy: 'Welcome' },
  minimumFetchIntervalMillis: 3600_000,
});

const on  = await UniTrack.getRemoteValue('feature_camera_grid', false);
const txt = await UniTrack.getRemoteValue('home_banner_copy', '');
```

## License

MIT — see [LICENSE](LICENSE).
