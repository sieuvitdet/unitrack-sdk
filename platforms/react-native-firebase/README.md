# @unitrack/firebase

Firebase **Analytics** provider for
[@unitrack/react-native](https://www.npmjs.com/package/@unitrack/react-native).
Mirrors every UniTrack event into Firebase Analytics so marketing keeps their
funnels, audiences, and BigQuery export — without wiring two SDKs by hand.

> **Analytics only.** Earlier releases shipped helper façades for Firebase
> Messaging (FCM), Crashlytics, and Remote Config. Those were removed in
> `1.1.0` to keep this package scoped to tracking. Apps that need those
> Firebase modules wire them directly — UniTrack stays out of the way.

## Install

```bash
npm install @unitrack/firebase \
  @react-native-firebase/app \
  @react-native-firebase/analytics
cd ios && pod install
```

You also need the standard `@react-native-firebase` setup:

- Android: `android/app/google-services.json` + the
  `com.google.gms.google-services` Gradle plugin.
- iOS: `ios/<App>/GoogleService-Info.plist` added to your app target.

## Wire it up

```ts
import { UniTrack } from '@unitrack/react-native';
import { FirebaseProvider } from '@unitrack/firebase';

UniTrack.addProvider(new FirebaseProvider());
await UniTrack.initialize('utk_your_api_key');
```

That's it. Every call to `UniTrack.track(...)`, every auto-captured screen
view / tap / network event, and every `UniTrack.identify(...)` will fan a copy
into Firebase Analytics.

## What gets forwarded

| UniTrack call | Firebase Analytics call |
| --- | --- |
| `UniTrack.track(name, props)` | `logEvent(name, props)` |
| `UniTrack.identify(userId, traits)` | `setUserId(userId)` + `setUserProperty(...)` per trait |
| auto-captured `screen_view` | `logScreenView({ screen_name, screen_class })` |

Event and parameter names are sanitised to match Firebase's rules:

- Names: alphanumeric + underscore, must start with a letter, ≤ 40 chars.
- Values: string / number / boolean only; longer strings truncated to 100 chars.

So calling `UniTrack.track('user-logged-in', { plan: 'pro' })` reaches
Firebase as `user_logged_in` with `plan=pro`. Non-conforming names are
prefixed with `e_` rather than dropped.

## Session stamping (1.1.0)

The native `FirebaseAdapter` underneath `@unitrack/react-native` calls
`Analytics.setDefaultEventParameters({ session_id })` at initialize, when the
session rotates, and on identity change. Result: even events the app fires
**directly** through `@react-native-firebase/analytics` (bypassing UniTrack)
carry the current UniTrack `session_id`.

Requires:

- Firebase iOS SDK 8.4+
- Firebase Android SDK 21.0.0+

Older SDKs are detected at runtime and become a safe no-op.

## License

MIT — see [LICENSE](LICENSE).
