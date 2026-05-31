// unitrack_snowplow — forwards every UniTrack event to a Snowplow collector.
//
// Usage:
//   UniTrack.instance.addProvider(SnowplowProvider(
//     endpoint: 'https://collector.example.com',
//     appId: '701',
//     userContext: {'username': 'duc', 'epcode': 'FTEL123'},
//     userContextSchema: 'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
//     schemas: {
//       // UniTrack event name -> iglu schema for a self-describing event.
//       'add_to_cart': 'iglu:com.acme/add_to_cart/jsonschema/1-0-0',
//     },
//   ));
//   await UniTrack.instance.initialize(apiKey);
//
// Events with a matching entry in [schemas] are sent as self-describing events;
// everything else is sent as a Snowplow Structured event (category 'unitrack',
// action = event name). The optional user context entity is attached to every
// event, mirroring MobiX's snowplow_service.dart.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:snowplow_tracker/snowplow_tracker.dart';
import 'package:unitrack/unitrack.dart';

class SnowplowProvider extends AnalyticsProvider {
  SnowplowProvider({
    required this.endpoint,
    required this.appId,
    this.namespace = 'UniTrack',
    this.userContext,
    this.userContextSchema,
    this.schemas = const {},
    this.options = const SnowplowOptions(),
    this.portalEndpoint,
    this.portalApiKey,
  });

  /// When set, every event tracked through Snowplow is ALSO mirrored to the
  /// UniTrack portal (tagged provider=snowplow) — so the session IDE shows
  /// exactly what Snowplow received, side-by-side with the unitrack event.
  /// Same mechanism FirebaseProvider uses.
  final String? portalEndpoint;
  final String? portalApiKey;

  /// Snowplow tracker flags the developer controls.
  final SnowplowOptions options;

  /// Snowplow collector URL.
  final String endpoint;

  /// Snowplow application id.
  final String appId;

  /// Tracker namespace (default 'UniTrack').
  final String namespace;

  /// Optional custom user-context entity attached to every event. Combined
  /// with [userContextSchema] into a SelfDescribing entity.
  Map<String, Object?>? userContext;

  /// Iglu schema URI for [userContext]. Required if [userContext] is set.
  final String? userContextSchema;

  /// Map of UniTrack event name -> iglu schema URI. Matching events become
  /// self-describing events; others fall back to Structured events. Mutable
  /// because the typical wiring is: provider is created at app init (sync)
  /// but the remote config is fetched a beat later — applyFromRemoteConfig()
  /// rewrites this map without forcing a re-init of the underlying tracker.
  Map<String, String> schemas;

  /// Replace the schemas map at runtime (e.g. from remote config). Existing
  /// entries are dropped; pass an empty map to disable self-describing
  /// fan-out and fall back to Structured for everything.
  void setSchemas(Map<String, String> next) {
    schemas = Map<String, String>.from(next);
    debugPrint('[unitrack_snowplow] schemas updated: ${schemas.length} entries');
  }

  SnowplowTracker? _tracker;

  @override
  Future<void> init() async {
    if (endpoint.isEmpty) {
      debugPrint('[unitrack_snowplow] empty endpoint — provider disabled');
      return;
    }
    _tracker = await Snowplow.createTracker(
      namespace: namespace,
      endpoint: endpoint,
      method: Method.post,
      trackerConfig: TrackerConfiguration(
        appId: appId,
        devicePlatform: DevicePlatform.mob,
        base64Encoding: options.base64Encoding,
        platformContext: options.platformContext,
        applicationContext: options.applicationContext,
        sessionContext: options.sessionContext,
        screenContext: options.screenContext,
        lifecycleAutotracking: options.lifecycleAutotracking,
        screenEngagementAutotracking: options.screenEngagementAutotracking,
      ),
    );
    debugPrint('[unitrack_snowplow] tracker ready ($endpoint, appId=$appId)');
  }

  /// Update the user-context entity values at runtime (e.g. after login).
  void updateUserContext(Map<String, Object?> ctx) => userContext = ctx;

  List<SelfDescribing> _contexts() {
    if (userContext == null || userContextSchema == null) return const [];
    return [
      SelfDescribing(
        schema: userContextSchema!,
        data: userContext!.map((k, v) => MapEntry(k, v ?? '')),
      ),
    ];
  }

  @override
  void track(String name, Map<String, Object?> properties) {
    final t = _tracker;
    if (t == null) return;
    final schema = schemas[name];
    Map<String, Object?> mirror;
    if (schema != null) {
      t.track(
        SelfDescribing(
          schema: schema,
          data: properties.map((k, v) => MapEntry(k, v ?? '')),
        ),
        contexts: _contexts(),
      );
      // Snowplow received this as a self-describing event — record both the
      // schema and the original properties so the portal can show them
      // exactly the way they went out on the wire.
      mirror = {
        '_sp_type': 'self_describing',
        '_sp_schema': schema,
        ...properties,
      };
    } else {
      // No registered schema → Structured event. Snowplow Structured only has
      // category/action/label/property/value, so fold a couple of common
      // properties into label/property for visibility.
      final label = properties['screen']?.toString() ??
          properties['screen_name']?.toString();
      final property = properties['element_key']?.toString() ??
          properties['state']?.toString();
      t.track(
        Structured(
          category: 'unitrack',
          action: name,
          label: label,
          property: property,
        ),
        contexts: _contexts(),
      );
      // Mirror reflects the Structured shape so the portal can show
      // category/action/label/property like Snowplow's own UI would.
      mirror = {
        '_sp_type': 'structured',
        '_sp_category': 'unitrack',
        '_sp_action': name,
        if (label != null) '_sp_label': label,
        if (property != null) '_sp_property': property,
        ...properties,
      };
    }
    _mirrorToPortal(name, mirror);
  }

  // Same fire-and-forget pattern as FirebaseProvider so the portal sees the
  // event as `provider=snowplow`. session_id is pulled off the event's own
  // properties when present (the SDK injects it on every event before fan-out).
  void _mirrorToPortal(String name, Map<String, Object?> properties) {
    final ep = portalEndpoint, key = portalApiKey;
    if (ep == null || key == null || ep.isEmpty || key.isEmpty) return;
    final uri = Uri.parse('$ep${ep.contains('?') ? '&' : '?'}provider=snowplow');
    final body = jsonEncode({
      'event_id': '${DateTime.now().microsecondsSinceEpoch}_$name',
      'event_name': name,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'properties': properties,
    });
    HttpClient().postUrl(uri).then((req) {
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Authorization', 'Bearer $key');
      req.add(utf8.encode(body));
      return req.close();
    }).then((resp) => resp.drain<void>()).catchError((_) {/* best effort */});
  }

  @override
  void setUser(String? userId, Map<String, Object?> traits) {
    _tracker?.setUserId(userId);
    if (traits.isNotEmpty && userContext != null) {
      userContext = {...userContext!, ...traits};
    }
  }

  @override
  void setScreen(String name) {
    _tracker?.track(ScreenView(name: name), contexts: _contexts());
  }
}

/// Snowplow TrackerConfiguration flags the developer can toggle. Defaults match
/// Snowplow's recommended mobile setup; override any flag as needed.
class SnowplowOptions {
  final bool base64Encoding;
  final bool platformContext;
  final bool applicationContext;
  final bool sessionContext;
  final bool screenContext;
  final bool lifecycleAutotracking;
  final bool screenEngagementAutotracking;

  const SnowplowOptions({
    this.base64Encoding = true,
    this.platformContext = true,
    this.applicationContext = true,
    this.sessionContext = true,
    this.screenContext = true,
    this.lifecycleAutotracking = true,
    this.screenEngagementAutotracking = true,
  });
}
