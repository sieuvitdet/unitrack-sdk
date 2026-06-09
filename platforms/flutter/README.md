# UniTrack

Universal mobile analytics SDK for Flutter. Auto-captures screens, taps, network
calls, crashes, OOM warnings, and JSON parse errors with a persistent offline
queue, session journey tracking, and W3C trace propagation.

- 📦 **Tiny integration** — one `initialize()` call, the rest is automatic.
- 🛰 **Offline-first** — events are queued to SQLite + retried with exponential
  backoff; nothing is dropped when the network is down.
- 🔁 **Session journey** — persistent `session_id` + `session_index` across cold
  starts; rotate manually on logout / context switch.
- 🧭 **W3C trace context** — opt-in `traceparent` injection on outbound HTTP for
  backend correlation.
- 🪝 **Provider fan-out** — every event is forwarded to optional providers
  (`unitrack_snowplow`, `unitrack_firebase`, custom).
- 📱 **Per-platform** — Swift on iOS, Kotlin on Android, C++ core inside both.

## Install

```yaml
dependencies:
  unitrack: ^1.0.0
```

## Initialize

```dart
import 'package:unitrack/unitrack.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UniTrack.instance.initialize(
    'utk_your_api_key',
    config: const UniTrackConfig(
      endpoint: 'https://your-portal.com/event-tracking/v1/events',
      batchSize: 20,
      flushIntervalMs: 5000,
    ),
  );
  runApp(const MyApp());
}
```

For Flutter route auto-tracking, add the navigator observer:

```dart
MaterialApp(
  navigatorObservers: [UniTrackNavigatorObserver()],
  ...
);
```

Install HTTP auto-capture (URL + duration + status for every request):

```dart
UniTrack.installHttpAutoCapture(
  excludeSubstrings: ['/heartbeat', 'firebaseinstallations'],
);
```

## Track custom events

```dart
UniTrack.instance.track('checkout_completed', properties: {
  'order_id': '1234',
  'amount': 99.95,
  'currency': 'USD',
});
```

## Identify a user

```dart
UniTrack.instance.identify('user_42', traits: {
  'plan': 'premium',
  'email': 'jane@example.com',
});
```

## Session helpers

The native core owns `session_id` rotation + persists `session_index` across
launches, so apps don't need to keep their own counter:

```dart
final id  = await UniTrack.instance.currentSessionId();
final idx = await UniTrack.instance.sessionIndex();         // 1, 2, 3, …
final prev = await UniTrack.instance.previousSessionId();   // for chaining

// Force a rotation on logout / switch-account:
await UniTrack.instance.rotateSession();
```

## Offline-queue debugging

While the device is offline, inspect what's still pending. Useful for a debug
toast during airplane-mode testing:

```dart
final pending = await UniTrack.instance.pendingEventCounts();
// {'ev_screen_view': 7, 'ev_click': 3, 'ev_session': 1}

// Auto-fire when a batch lands server-side:
final sub = UniTrack.instance.onFlushCompleted((counts) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Flushed: $counts')),
  );
});
```

## Remote config

Resolve runtime flags / strings without a rebuild. Order:

1. Portal `sdk_config.custom_values[key]` (operator-edited)
2. Firebase Remote Config (via `unitrack_firebase`)
3. Caller's `defaultValue`

```dart
final on  = await UniTrack.instance.getRemoteValue<bool>(
  'feature_camera_grid', defaultValue: false);
final ttl = await UniTrack.instance.getRemoteValue<int>(
  'retry_delay_ms', defaultValue: 1500);
```

## W3C tracing

```dart
UniTrack.instance.setTracing(
  enabled: true,
  allowlistHosts: ['api.your-app.com', '*.your-app.com'],
);
```

## Provider fan-out

Send the same events to Snowplow + Firebase by adding provider packages:

```yaml
dependencies:
  unitrack: ^1.0.0
  unitrack_snowplow: ^1.0.0   # optional
  unitrack_firebase: ^1.0.0   # optional
```

```dart
UniTrack.instance.addProvider(SnowplowProvider(
  endpoint: 'https://collector.your-app.com',
  appId: 'mobile-app',
));
UniTrack.instance.addProvider(FirebaseProvider());
await UniTrack.instance.initialize(apiKey);
```

## What's auto-captured

| Source | Event names |
|---|---|
| `UniTrackNavigatorObserver` | `screen_load_completed` |
| Tap auto-capture (native swizzling) | `click` |
| `installHttpAutoCapture` | `network_request` |
| `FlutterError.onError`, `PlatformDispatcher.onError` | `crash` |
| Native OOM signal | `memory_warning` |
| `safeJsonParse` | `json_parse_error` |
| Lifecycle | `app_foreground`, `app_background`, `session_started`, `session_ended` |

## License

MIT — see [LICENSE](LICENSE).
