# @unitrack/snowplow

Snowplow provider cho UniTrack React Native. Forward mọi event UniTrack
qua Snowplow collector + auto-attach 3 entity (user_context, core_action,
application_context). Parity với iOS + Android Snowplow provider.

## Cài

```bash
npm install @unitrack/snowplow @snowplow/react-native-tracker
```

`@snowplow/react-native-tracker` là peer dependency — app tự cài.

## Setup

```ts
import { UniTrack } from '@unitrack/react-native';
import { SnowplowProvider } from '@unitrack/snowplow';

UniTrack.addProvider(new SnowplowProvider({
  endpoint: 'https://ftracking.fpt.vn',
  appId: 'fli_rn',
  namespace: 'UniTrack',
  igluVendor: 'vn.fpt.ftel.snowplow',
  defaultVersion: '1-0-0',
  eventNames: {
    click: 'event_click',
    result: 'event_result',
    screen_view: 'event_screen_view',
    crash: 'event_crash',
    api: 'event_api',
    session: 'event_session',
  },
  entities: {
    user_context: 'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
    core_action: 'iglu:vn.fpt.ftel.snowplow/core_action/jsonschema/1-0-0',
    application_context: 'iglu:vn.fpt.ftel.snowplow/application_context/jsonschema/1-0-0',
  },
  userContext: { username: 'demo' },
  applicationContext: {
    platform: 'rn',
    app_version: '1.0.0',
    // ... fill từ device info app side
  },
}));

await UniTrack.initialize(API_KEY);
```

## 6 convention helper (parity iOS/Android)

```ts
const sp = new SnowplowProvider({ ... });

// 1) Click event
sp.trackingClickEvent({
  elementKey: 'login_button',
  label: 'Login',
  screen: 'LoginScreen',
  data: { tab: 'home' },
});

// 2) Result event (success/fail outcome)
sp.trackingResultEvent({
  action: 'camera_pairing',
  status: 'success',
  data: { camera_serial: 'CAM12345' },
});

// 3) Screen view
sp.trackingScreenView({
  screenName: 'StreamScreen',
  fromScreen: 'CameraListScreen',
  data: { camera_serial: 'CAM12345' },
});

// 4) Crash event
sp.trackingCrash({
  message: 'TypeError: undefined',
  fatal: false,
  type: 'TypeError',
});

// 5) API event
sp.trackingAPI({
  url: 'https://api.example.com/login',
  method: 'POST',
  status: 200,
  durationMs: 145,
});

// 6) Session event
sp.trackingSession({
  action: 'session_started',
  data: { session_id: '...', session_index: 1 },
});
```

## Hot-reload từ portal config

```ts
sp.setEventNames({ click: 'event_tap' });    // đổi tên kind → name
sp.setEntities({ user_context: 'iglu:...' }); // đổi schema URI
sp.updateUserContext({ username: '...' });
```

## Generic `track()` — qua AnalyticsProvider interface

```ts
UniTrack.track('camera_stream_started', { camera_serial: 'CAM12345' });
// → SnowplowProvider.track('camera_stream_started', {...})
// → schema URI = iglu:vn.fpt.ftel.snowplow/camera_stream_started/jsonschema/1-0-0
// → 3 entity tự attach
```

## Build + typecheck

```bash
npm run typecheck
npm run build
```
