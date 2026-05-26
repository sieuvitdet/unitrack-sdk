# unitrack_snowplow

Snowplow provider for [UniTrack](../). Forwards **every** UniTrack event
(taps, screens, network, crash, notifications, manual `track()`) to a Snowplow
collector. The core `unitrack` package has no Snowplow dependency — add this
package only when you want Snowplow forwarding.

## Install

```yaml
dependencies:
  unitrack:
    path: ../platforms/flutter
  unitrack_snowplow:
    path: ../platforms/flutter/unitrack_snowplow
```

## Use

Register the provider **before** `initialize()`:

```dart
import 'package:unitrack/unitrack.dart';
import 'package:unitrack_snowplow/unitrack_snowplow.dart';

UniTrack.instance.addProvider(SnowplowProvider(
  endpoint: 'https://your-collector.example.com',
  appId: '701',
  // Optional custom user-context entity attached to every event:
  userContext: {'username': 'duc', 'epcode': 'FTEL123'},
  userContextSchema: 'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
  // Optional: map UniTrack event names to self-describing schemas. Events not
  // listed here are sent as Snowplow Structured events (category 'unitrack').
  schemas: {
    'add_to_cart': 'iglu:com.acme/add_to_cart/jsonschema/1-0-0',
  },
));

await UniTrack.instance.initialize(apiKey);
```

- Events **with** a `schemas` entry → self-describing events.
- Events **without** → Structured events (`category='unitrack'`, `action=name`).
- `identify()` → `tracker.setUserId`; `setScreen()` → Snowplow `ScreenView`.

Mirrors the Snowplow setup used in MobiX (namespace, POST, base64, platform/
session/screen contexts).
