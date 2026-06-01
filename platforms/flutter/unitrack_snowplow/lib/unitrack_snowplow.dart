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

  /// Snowplow tracker flags the developer controls. Mutable because the
  /// typical wiring is: provider created at app init (sync) → remote config
  /// fetched a beat later → applyOptions() rebuilds the tracker with the
  /// portal-supplied flags. The previous SnowplowTracker reference is dropped;
  /// Snowplow's plugin doesn't expose an explicit close, but a new tracker
  /// fully replaces the old one on the native side.
  SnowplowOptions options;

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

  // ── Blueprint config ────────────────────────────────────────────────────
  //
  // `schemas` only covers "event_name → one schema URI". FPT's analytics
  // taxonomy (and Snowplow's own model) needs more: each event ships with
  // context entities (user_context, core_action, attendance, …) whose own
  // schemas + field maps come from the backend team's spec, NOT from app
  // code. Blueprints encode that.
  //
  // _blueprints[id] = { schema, attach_entities[] }
  //   one blueprint per event "kind" (click_event, result_event, …) so 21
  //   events sharing the same ev_click schema reuse one blueprint entry.
  //
  // _entities[id]   = { schema, fields{name → {from, key, default?}} }
  //   one definition per context entity. `from` is the value source —
  //   "globals" (app-supplied via setGlobalContext), "device" (UniTrack
  //   device blob), "props" (per-event properties), or "literal".
  //
  // _eventBlueprintMap[name_or_pattern] = blueprint_id
  //   exact match wins; wildcard `prefix_*` matches by startsWith.
  Map<String, Map<String, Object?>> _blueprints = {};
  Map<String, Map<String, Object?>> _entities = {};
  Map<String, String>               _eventBlueprintMap = {};

  /// Globals are values that don't live on a single event but get attached
  /// to its context entities (user info, build flavor, …). One write per
  /// app session is normal — call from your "user logged in" code path.
  Map<String, Object?> _globals = {};
  void setGlobalContext(Map<String, Object?> ctx) {
    _globals = Map<String, Object?>.from(ctx);
    debugPrint('[unitrack_snowplow] globals updated (${_globals.length} keys)');
  }
  void mergeGlobalContext(Map<String, Object?> ctx) {
    _globals = { ..._globals, ...ctx };
  }

  /// Device blob from the SDK init (DeviceInfo.json). Apps push it via
  /// setDeviceBlob so the provider can pull device.* fields when an entity
  /// field's source is "device". We DON'T import the C bridge here just for
  /// this — pull-on-write keeps the provider unitrack-package-agnostic.
  Map<String, Object?> _deviceBlob = {};
  void setDeviceBlob(Map<String, Object?> blob) {
    _deviceBlob = Map<String, Object?>.from(blob);
  }

  /// Replace the blueprint config wholesale (typically from remote config).
  /// Pass empty maps to fall back to the legacy schemas[] behaviour.
  void applyBlueprintConfig({
    Map<String, Map<String, Object?>>? blueprints,
    Map<String, Map<String, Object?>>? entities,
    Map<String, String>? eventBlueprintMap,
  }) {
    if (blueprints != null) _blueprints = Map<String, Map<String, Object?>>.from(blueprints);
    if (entities != null)   _entities   = Map<String, Map<String, Object?>>.from(entities);
    if (eventBlueprintMap != null) _eventBlueprintMap = Map<String, String>.from(eventBlueprintMap);
    debugPrint('[unitrack_snowplow] blueprints=${_blueprints.length} entities=${_entities.length} mapped=${_eventBlueprintMap.length}');
  }

  // Resolve an event name to a blueprint id. Exact match wins; otherwise
  // walk patterns with a trailing `_*` and return the first prefix match.
  // null = no blueprint, fall back to schemas[name] or Structured.
  String? _resolveBlueprintId(String eventName) {
    final exact = _eventBlueprintMap[eventName];
    if (exact != null) return exact;
    for (final entry in _eventBlueprintMap.entries) {
      final pat = entry.key;
      if (pat.endsWith('*')) {
        final prefix = pat.substring(0, pat.length - 1);
        if (eventName.startsWith(prefix)) return entry.value;
      }
    }
    return null;
  }

  // Pull a value from the configured source. Returns null if missing —
  // the caller decides what to do (some entities require all fields).
  Object? _pullField(Map<String, Object?> field, Map<String, Object?> props, String eventName) {
    final from = (field['from'] ?? 'literal') as String;
    final key  = (field['key']  ?? '')        as String;
    Object? raw;
    switch (from) {
      case 'globals':
        raw = _readDottedKey(_globals, key);
        break;
      case 'device':
        raw = _readDottedKey(_deviceBlob, key);
        break;
      case 'props':
        raw = _readDottedKey(props, key);
        break;
      case 'event_name':
        raw = eventName;
        break;
      case 'literal':
        raw = field['value'];
        break;
    }
    if (raw != null && raw.toString().isNotEmpty) return raw;
    // default token — "now" → ISO timestamp; anything else → literal default.
    final def = field['default'];
    if (def == 'now') return DateTime.now().toIso8601String();
    return def;
  }

  /// `user.userName` → walk `globals['user']['userName']`. Plain strings
  /// without a `.` read one level.
  Object? _readDottedKey(Map<String, Object?> bag, String key) {
    if (key.isEmpty) return null;
    final parts = key.split('.');
    Object? cur = bag;
    for (final p in parts) {
      if (cur is Map) {
        cur = cur[p];
      } else {
        return null;
      }
      if (cur == null) return null;
    }
    return cur;
  }

  /// Build one entity into a Snowplow SelfDescribing context. Returns null
  /// if the entity isn't configured OR every field came back null (no point
  /// shipping an entity full of empty strings; backend schema validation
  /// would likely reject anyway).
  SelfDescribing? _buildEntity(String entityId, Map<String, Object?> props, String eventName) {
    final ent = _entities[entityId];
    if (ent == null) return null;
    final schema = ent['schema'] as String?;
    if (schema == null || schema.isEmpty) return null;
    final fieldMap = (ent['fields'] as Map?)?.cast<String, Object?>() ?? const {};
    final data = <String, Object?>{};
    var anyValue = false;
    for (final f in fieldMap.entries) {
      final spec = (f.value as Map?)?.cast<String, Object?>() ?? const {};
      final v = _pullField(spec, props, eventName);
      if (v != null && v.toString().isNotEmpty) anyValue = true;
      // Snowplow doesn't like null values inside a SelfDescribing — coerce
      // to empty string. The backend schema can reject empties if needed.
      data[f.key] = v ?? '';
    }
    if (!anyValue) return null;
    return SelfDescribing(schema: schema, data: data);
  }

  /// Strip internal-only keys (anything starting with `_`) before they
  /// reach the SelfDescribing data field — those are inputs for context
  /// entities (vd `_start_time` → core_action.start_time), not part of the
  /// event's own schema.
  Map<String, Object?> _cleanedEventData(Map<String, Object?> props) {
    final out = <String, Object?>{};
    for (final e in props.entries) {
      if (e.key.startsWith('_')) continue;
      out[e.key] = e.value ?? '';
    }
    return out;
  }

  /// Replace the schemas map at runtime (e.g. from remote config). Existing
  /// entries are dropped; pass an empty map to disable self-describing
  /// fan-out and fall back to Structured for everything.
  void setSchemas(Map<String, String> next) {
    schemas = Map<String, String>.from(next);
    debugPrint('[unitrack_snowplow] schemas updated: ${schemas.length} entries');
  }

  /// Apply the Snowplow TrackerConfiguration flags from remote config. Any
  /// key NOT in [overrides] keeps its current value, so the operator only
  /// needs to send the flags they actually changed.
  ///
  /// The native tracker is rebuilt — Snowplow's TrackerConfiguration is
  /// immutable after createTracker, so applying lifecycleAutotracking=true
  /// (or any other field) requires a fresh tracker. The first event sent
  /// AFTER applyOptions reflects the new config.
  Future<void> applyOptions(Map<String, bool> overrides) async {
    if (overrides.isEmpty) return;
    final cur = options;
    options = SnowplowOptions(
      base64Encoding:               overrides['base64Encoding']               ?? cur.base64Encoding,
      platformContext:              overrides['platformContext']              ?? cur.platformContext,
      applicationContext:           overrides['applicationContext']           ?? cur.applicationContext,
      sessionContext:               overrides['sessionContext']               ?? cur.sessionContext,
      screenContext:                overrides['screenContext']                ?? cur.screenContext,
      lifecycleAutotracking:        overrides['lifecycleAutotracking']        ?? cur.lifecycleAutotracking,
      screenEngagementAutotracking: overrides['screenEngagementAutotracking'] ?? cur.screenEngagementAutotracking,
    );
    debugPrint('[unitrack_snowplow] options updated: $overrides — rebuilding tracker');
    await _rebuildTracker();
  }

  // Re-create the underlying SnowplowTracker with the current [options] +
  // endpoint/appId/namespace. Used by applyOptions(); kept private so the
  // tracker lifecycle stays inside the provider.
  Future<void> _rebuildTracker() async {
    if (endpoint.isEmpty) return;
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
    Map<String, Object?> mirror;

    // Resolution order (richest first → simplest):
    //   1. Blueprint match → SelfDescribing with attach_entities
    //   2. Plain schemas[name] map → SelfDescribing with the global user_context only
    //   3. Structured event (category/action/label/property)
    //
    // (1) is the path FPT taxonomy needs: one click_event blueprint serves
    // every ev_click_* event, with core_action + user_context entities
    // assembled from globals + per-event props. App code stays free of
    // schema URIs and entity field shapes.
    final blueprintId = _resolveBlueprintId(name);
    final blueprint = blueprintId != null ? _blueprints[blueprintId] : null;

    if (blueprint != null && (blueprint['schema'] as String?)?.isNotEmpty == true) {
      final schema = blueprint['schema'] as String;
      final attach = (blueprint['attach_entities'] as List?)?.cast<String>() ?? const [];
      final contexts = <SelfDescribing>[];
      for (final entId in attach) {
        final entity = _buildEntity(entId, properties, name);
        if (entity != null) contexts.add(entity);
      }
      // Also keep the legacy global user_context entity if it wasn't already
      // built by the blueprint — apps with both old + new wiring don't lose it.
      if (!attach.contains('user_context')) {
        contexts.addAll(_contexts());
      }
      final data = _cleanedEventData(properties);
      t.track(
        SelfDescribing(schema: schema, data: data),
        contexts: contexts,
      );
      mirror = {
        '_sp_type': 'self_describing',
        '_sp_schema': schema,
        '_sp_blueprint': blueprintId,
        '_sp_contexts': attach,        // entity ids that were resolved
        ...data,
      };
    } else if (schemas[name] != null) {
      // Legacy path — single-schema map, no blueprint context list.
      final schema = schemas[name]!;
      t.track(
        SelfDescribing(
          schema: schema,
          data: _cleanedEventData(properties),
        ),
        contexts: _contexts(),
      );
      mirror = {
        '_sp_type': 'self_describing',
        '_sp_schema': schema,
        ..._cleanedEventData(properties),
      };
    } else {
      // No schema at all → Structured event fallback. Snowplow Structured
      // only has category/action/label/property/value — fold the two common
      // props into label/property for visibility on the collector.
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
      mirror = {
        '_sp_type': 'structured',
        '_sp_category': 'unitrack',
        '_sp_action': name,
        if (label != null) '_sp_label': label,
        if (property != null) '_sp_property': property,
        ..._cleanedEventData(properties),
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
