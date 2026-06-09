# unitrack_snowplow

Snowplow provider for [UniTrack](https://pub.dev/packages/unitrack). Forwards
every UniTrack event to a Snowplow collector with the SDK's built-in convention
layer, auto-attached `user_context` + `application_context` entities, and
per-event Iglu schema resolution.

## Install

```yaml
dependencies:
  unitrack: ^1.0.0
  unitrack_snowplow: ^1.0.0
```

## Wire-up

```dart
import 'package:unitrack/unitrack.dart';
import 'package:unitrack_snowplow/unitrack_snowplow.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  UniTrack.instance.addProvider(SnowplowProvider(
    endpoint: 'https://collector.your-app.com',
    appId: 'mobile-app',
    namespace: 'YourApp',
    igluVendor: 'com.your-app',          // optional — falls back per-event
    defaultVersion: '1-0-0',
  ));
  await UniTrack.instance.initialize('utk_your_api_key');
  runApp(const MyApp());
}
```

`addProvider` BEFORE `initialize()` so the provider is up before the first event.

## What it does

For every UniTrack event the provider:

1. Resolves the right Iglu schema — checks `eventNames` overrides, then falls
   back to `igluVendor/<event_kind>/jsonschema/<defaultVersion>`.
2. Attaches `user_context` + `application_context` as Snowplow entities so the
   collector receives the same device/app metadata UniTrack core stamps on the
   wire payload.
3. Routes screen events (`screen_viewed` / `screen_exited` /
   `screen_load_completed`) to the same `screen_view` kind, with `event_action`
   stamped so sibling events under that schema stay distinguishable.

## Convention helpers

Use these when you want a typed shape that matches a known Iglu schema:

```dart
sp.trackingClickEvent(elementKey: 'cta_buy', screen: 'CheckoutScreen');

sp.trackingResultEvent(
  action: 'payment_charge',
  status: 'success',
  durationMs: 842,
);

sp.trackingScreenView(screenName: 'HomeScreen');
sp.trackingCrash(message: 'NullPointerException', stack: trace);
sp.trackingAPI(url: '/v1/orders', method: 'POST', status: 200, durationMs: 320);
sp.trackingSession(action: 'session_started');
```

## Portal mirror

Pair with a UniTrack portal to see what's going to Snowplow side-by-side with
other providers:

```dart
SnowplowProvider(
  endpoint: '...',
  appId: '...',
  portalEndpoint: 'https://your-portal.com/event-tracking/v1/events',
  portalApiKey:   'utk_your_api_key',
);
```

## License

MIT — see [LICENSE](LICENSE).
