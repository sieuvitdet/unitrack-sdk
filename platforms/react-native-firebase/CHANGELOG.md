# Changelog

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
