// Central tracking setup for the demo app.
//
// Everything funnels through UniTrack.instance. The native side (iOS/Android)
// auto-captures screen_view, tap, network_request, app_foreground/background,
// memory_warning and crash. On top of that we fire rich *manual* business
// events from the screens so the portal sees a realistic event stream.

import 'package:unitrack/unitrack.dart';

// --- Multi-provider (Snowplow / Firebase) -------------------------------------
// These are OPTIONAL. Add them to pubspec.yaml and uncomment the imports +
// addProvider() calls below to ALSO forward every UniTrack event to Snowplow
// and/or Firebase. Without them the app builds and runs exactly as before.
//
//   dependencies:
//     unitrack_snowplow: { path: ../platforms/flutter/unitrack_snowplow }
//     unitrack_firebase: { path: ../platforms/flutter/unitrack_firebase }
//
// Firebase also needs google-services.json (android/app) + GoogleService-Info.plist
// (ios/Runner) and the google-services gradle plugin applied in the app.
//
// import 'package:unitrack_snowplow/unitrack_snowplow.dart';
// import 'package:unitrack_firebase/unitrack_firebase.dart';

class Tracking {
  Tracking._();

  /// Where events are shipped. This is the Mobix portal ingest endpoint.
  static const String endpoint =
      'https://mobix.asia/event-tracking-mobile/v1/events';

  /// API key for this app. The portal currently ingests open (no key required),
  /// but the SDK still tags events with it so the backend can attribute them.
  static const String apiKey = 'utk_FPxp0q7RK3jja0CnFp3WEx9Q';

  /// Remote-config endpoint. The app fetches its tracking config here at startup
  /// so endpoint / providers / event-rewrite rules can change without rebuilding.
  static const String configURL =
      'https://mobix.asia/event-tracking-mobile/config';

  static Future<void> init() async {
    // 1. Fetch remote config from the portal (cache/default fallback on failure,
    //    so launch never blocks even offline).
    final cfg = await UniTrackRemoteConfig.fetch(
      apiKey: apiKey, configURL: configURL,
      timeout: const Duration(seconds: 3),
    );

    // 2. Install config-driven event-rewrite rules (Phase 2). Now a tap/screen
    //    can be renamed to a business event from the portal, no app change.
    UniTrack.instance.setEventRules(cfg.toEventRules());

    // (Optional) register Snowplow/Firebase here using values from `cfg` —
    // see the camera demo for the full pattern.

    // 3. Initialize the SDK from the fetched config (sdk_config + endpoint).
    final s = cfg.sdkConfig;
    await UniTrack.instance.initialize(
      apiKey,
      config: UniTrackConfig(
        endpoint: cfg.endpoint ?? endpoint,
        batchSize: (s['batchSize'] as num?)?.toInt() ?? 10,
        flushIntervalMs: (s['flushIntervalMs'] as num?)?.toInt() ?? 3000,
        samplingRate: (s['samplingRate'] as num?)?.toDouble() ?? 1.0,
        autoCapture: s['autoCapture'] as bool? ?? true,
        trackScreens: s['trackScreens'] as bool? ?? true,
        trackTaps: s['trackTaps'] as bool? ?? true,
        trackNetwork: s['trackNetwork'] as bool? ?? true,
      ),
    );
  }

  // --- thin helpers used across screens -----------------------------------

  static Future<void> event(String name, [Map<String, Object?>? props]) =>
      UniTrack.instance.track(name, properties: props);

  static Future<void> identify(String userId, {Map<String, Object?>? traits}) =>
      UniTrack.instance.identify(userId, traits: traits);

  static Future<void> reset() => UniTrack.instance.reset();

  static Future<void> flush() => UniTrack.instance.flush();

  /// Manually mark the current screen. Native auto-capture also reports
  /// screens, but explicit setScreen makes routes without names readable.
  static Future<void> screen(String name) =>
      UniTrack.instance.setScreen(name);
}
