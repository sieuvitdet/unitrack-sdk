# @unitrack/react-native

Universal mobile analytics SDK for React Native. Auto-captures screens, taps,
network calls, crashes, OOM warnings, and JSON parse errors with a persistent
offline queue, session journey tracking, and W3C trace propagation.

- 📦 **Tiny integration** — one `initialize()` call, the rest is automatic.
- 🛰 **Offline-first** — events queue to SQLite + retry with exponential
  backoff; nothing is dropped when the network is down.
- 🔁 **Session journey** — persistent `session_id` + `session_index` across
  cold starts; rotate manually on logout / context switch.
- 🧭 **W3C trace context** — opt-in `traceparent` injection on outbound HTTP for
  backend correlation.
- 🪝 **Provider fan-out** — every event forwarded to optional providers
  ([`@unitrack/snowplow`](https://www.npmjs.com/package/@unitrack/snowplow),
  [`@unitrack/firebase`](https://www.npmjs.com/package/@unitrack/firebase),
  custom).
- 📱 **Per-platform** — Swift on iOS, Kotlin on Android, C++ core inside both.

## Install

```bash
npm install @unitrack/react-native
# iOS
cd ios && pod install
```

## Initialize

```ts
import { UniTrack } from '@unitrack/react-native';

await UniTrack.initialize('utk_your_api_key', {
  endpoint: 'https://your-portal.com/event-tracking/v1/events',
  batchSize: 20,
  flushIntervalMs: 5000,
});
```

## Track custom events

```ts
UniTrack.track('checkout_completed', {
  order_id: '1234',
  amount: 99.95,
  currency: 'USD',
});
```

## Identify a user

```ts
UniTrack.identify('user_42', { plan: 'premium', email: 'jane@example.com' });
```

## Session helpers

The native core owns `session_id` rotation + persists `session_index` across
launches, so apps don't keep their own counter:

```ts
const id   = await UniTrack.currentSessionId();
const idx  = await UniTrack.sessionIndex();          // 1, 2, 3, …
const prev = await UniTrack.previousSessionId();     // for chaining

// Force a rotation on logout / switch-account:
await UniTrack.rotateSession();
```

## Offline-queue debugging

```ts
const pending = await UniTrack.pendingEventCounts();
// { ev_screen_view: 7, ev_click: 3, ev_session: 1 }

// Auto-fire when a batch lands server-side:
const sub = UniTrack.onFlushCompleted((counts) => {
  console.log('Flushed', counts);
});
// later: sub.remove();
```

## Remote config

Resolve runtime flags / strings without a rebuild. Order:

1. Portal `sdk_config.custom_values[key]` (operator-edited)
2. Firebase Remote Config (via `@unitrack/firebase`)
3. Caller's defaultValue

```ts
const on  = await UniTrack.getRemoteValue('feature_camera_grid', false);
const ttl = await UniTrack.getRemoteValue('retry_delay_ms', 1500);
```

## W3C tracing

```ts
UniTrack.setTracing({
  enabled: true,
  allowlistHosts: ['api.your-app.com', '*.your-app.com'],
});
```

## React Navigation auto-capture

```tsx
import { UniTrackRouteObserver } from '@unitrack/react-native';

<NavigationContainer onStateChange={UniTrackRouteObserver.onStateChange}>
  ...
</NavigationContainer>
```

## Provider fan-out

```ts
import { UniTrack } from '@unitrack/react-native';
import { SnowplowProvider } from '@unitrack/snowplow';
import { FirebaseProvider } from '@unitrack/firebase';

UniTrack.addProvider(new SnowplowProvider({
  endpoint: 'https://collector.your-app.com',
  appId: 'mobile-app',
}));
UniTrack.addProvider(new FirebaseProvider());
await UniTrack.initialize(apiKey);
```

## License

MIT — see [LICENSE](LICENSE).
