# Changelog

## 1.0.0 — 2026-06-09

Initial public release.

- `SnowplowProvider` implements `AnalyticsProvider` so any UniTrack event
  fans out to the configured Snowplow collector.
- Auto-attached entities: `user_context`, `core_action`,
  `application_context` — same shape the native iOS / Android providers send.
- `kindForRawEvent` routing: `screen_viewed`, `screen_exited`,
  `screen_load_completed` → `screen_view` kind with stamped `event_action`.
- Built-in convention helpers: `trackingClickEvent`, `trackingResultEvent`,
  `trackingScreenView`, `trackingCrash`, `trackingAPI`, `trackingSession`.
- Per-event Iglu schema resolution with `igluVendor`, `defaultVersion`,
  `eventNames` overrides, and per-name `entities` map.
- Optional portal mirror for side-by-side log inspection.
