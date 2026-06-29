# Changelog

## 1.1.0 — 2026-06-23

### Changed

- **Analytics-only scope.** The package is now narrowly defined as the
  Firebase **Analytics** mirror for `@unitrack/react-native`. Helper façades
  for FCM, Crashlytics, and Remote Config that shipped in 1.0.0 are gone —
  apps wire those Firebase modules directly.

### Added

- Session stamping via the underlying native `FirebaseAdapter`
  (`setDefaultEventParameters({ session_id })` at `initialize` / on session
  rotate / on `setUser`). Events fired **directly** through
  `@react-native-firebase/analytics` (bypassing `UniTrack.track`) now also
  carry the current UniTrack `session_id`. Requires Firebase iOS SDK 8.4+ /
  Firebase Android SDK 21.0.0+ (older SDKs no-op safely).

### Removed

- `UniTrackFirebaseMessaging` (token + foreground / opened-app / background
  message helpers).
- `UniTrackFirebaseCrashlytics` (`recordError`, `setCustomKey`, `log`,
  `syncUser`).
- `UniTrackFirebaseRemoteConfig` (`activate`, `getString/Bool/Number` +
  Portal-first resolver chain).
- The matching optional peer dependencies on
  `@react-native-firebase/messaging`, `@react-native-firebase/crashlytics`,
  and `@react-native-firebase/remote-config`.

### Migration

If you previously called any of the removed helpers, switch to the
`@react-native-firebase/*` module directly:

```ts
// Before
import { UniTrackFirebaseCrashlytics } from '@unitrack/firebase';
await UniTrackFirebaseCrashlytics.recordError(e);

// After
import crashlytics from '@react-native-firebase/crashlytics';
crashlytics().recordError(e);
UniTrack.track('application_error', { message: String(e) });
```

## 1.0.0 — 2026-06-09

Initial public release.

- `FirebaseProvider` forwards every UniTrack event to Firebase Analytics with
  name + parameter sanitisation that matches Firebase's strict rules.
- `UniTrackFirebaseMessaging` — `handleTokenUpdate` (deduped),
  `handleNotificationReceivedForeground`, `handleNotificationClicked`,
  `handleBackgroundMessage`. Routes through `UniTrack.trackNotification`.
- `UniTrackFirebaseCrashlytics` — `recordError`, `setCustomKey`, `log`,
  `syncUser`. Records to Crashlytics AND fires `application_error`.
- `UniTrackFirebaseRemoteConfig` — `activate()` with defaults +
  `getString/Bool/Number`. Plugs into `UniTrack.getRemoteValue<T>` chain.
- Optional peer dependencies for Messaging / Crashlytics / Remote Config
  modules so apps only install what they use.
