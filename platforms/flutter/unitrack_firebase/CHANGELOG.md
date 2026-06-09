# Changelog

## 1.0.0 — 2026-06-09

Initial public release.

- `FirebaseProvider` forwards every UniTrack event to Firebase Analytics with
  name + parameter sanitisation that matches Firebase's strict rules.
- Super properties + user properties (init-time + runtime mutations).
- Helpers shipped alongside the provider:
  - `UniTrackFirebaseMessaging` — handles FCM token updates + push
    notifications (foreground, click, background). Plumbs into
    `UniTrack.trackNotification` and emits `fcm_token_updated`.
  - `UniTrackFirebaseCrashlytics` — `recordError`, `setCustomKey`, `log`,
    `syncUser`. Records to Crashlytics AND fires `application_error` so the
    portal sees the same incident.
  - `UniTrackFirebaseRemoteConfig` — Firebase RC activation +
    `getString/Bool/Int/Double` getters. Plugs into the unified
    `UniTrack.getRemoteValue<T>` resolver chain.
- Optional portal mirror so the UniTrack portal can show a copy of every
  event tagged `provider=firebase`.
