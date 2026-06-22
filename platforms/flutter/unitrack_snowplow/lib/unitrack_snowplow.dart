// unitrack_snowplow — forwards every UniTrack event to a Snowplow collector.
//
// Convention layer (parity with iOS + Android Snowplow providers):
//
//   UniTrack.instance.addProvider(SnowplowProvider(
//     endpoint:       'https://ftracking.fpt.vn',
//     appId:          'fli',
//     igluVendor:     'vn.fpt.ftel.snowplow',
//     defaultVersion: '1-0-0',
//     // Convention kind → wire event name. Portal overrides these so the
//     // taxonomy moves without rebuilding the app.
//     eventNames: { 'click': 'event_click', 'result': 'event_result', ... },
//     // Auto-attached context entities — entity short name → iglu URI.
//     entities:   { 'user_context': 'iglu:.../user_context/.../1-0-0',
//                   'core_action':  'iglu:.../core_action/.../1-0-0' },
//     // Per-user bag stamped on every event's user_context entity.
//     userContext: { 'user_id': 'demo_user_42', 'plan': 'b2c_premium' },
//   ));
//
// Each track() resolves the event name through `eventNames` and the schema
// through `igluVendor + defaultVersion`, then attaches `user_context` and
// `core_action` entities by default. Events without an iglu vendor fall back
// to Snowplow Structured (category 'unitrack', action = event name) so the
// collector still sees something even with a half-configured project.
//
// Use the convention helpers (trackingClickEvent / trackingResultEvent /
// trackingAPI / trackingScreenView / trackingCrash) for the 5 sheet kinds —
// they build the right payload + schema URI + entity contexts in one call,
// same shape as iOS/Android.

import 'dart:async';
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
    Map<String, Object?>? userContext,
    this.options = const SnowplowOptions(),
    this.igluVendor,
    this.defaultVersion = '1-0-0',
    Map<String, String> eventNames = const {},
    Map<String, String> entities = const {},
    this.portalEndpoint,
    this.portalApiKey,
  })  : userContext = userContext == null
            ? <String, Object?>{}
            : Map<String, Object?>.from(userContext),
        _eventNames = Map<String, String>.from(eventNames),
        _entities = Map<String, String>.from(entities);

  /// When set, every event tracked through Snowplow is ALSO mirrored to the
  /// UniTrack portal (tagged provider=snowplow) — so the session IDE shows
  /// exactly what Snowplow received, side-by-side with the unitrack event.
  /// Same mechanism FirebaseProvider uses.
  final String? portalEndpoint;
  final String? portalApiKey;

  /// Snowplow TrackerConfiguration flags. Mutable because remote config can
  /// arrive after construction — applyOptions() rebuilds the tracker.
  SnowplowOptions options;

  /// Snowplow collector URL.
  final String endpoint;

  /// Snowplow application id.
  final String appId;

  /// Tracker namespace (default 'UniTrack').
  final String namespace;

  /// Convention vendor — schema URI is `iglu:<igluVendor>/<name>/jsonschema/<defaultVersion>`.
  String? igluVendor;

  /// Iglu schema version segment, e.g. `1-0-0`.
  String defaultVersion;

  /// Convention kind → wire event name (portal `event_names.<kind>`). Built-in
  /// kinds: click / result / screen_view / crash / api. Custom kinds register
  /// here too so the SDK can emit them without an app rebuild.
  Map<String, String> _eventNames;
  Map<String, String> get eventNames => _eventNames;

  /// Auto-attached context entity short-name → iglu URI. Two well-known ids
  /// are used by the convention helpers:
  ///   user_context — built from the [userContext] bag.
  ///   core_action  — built from event meta (action_name + timestamp + screen
  ///                  + element_key).
  /// Any other id is reserved for app code passing `extraContexts`.
  Map<String, String> _entities;
  Map<String, String> get entities => _entities;

  /// Per-user properties attached to every event under the user_context entity
  /// (if `entities['user_context']` is set). Mutate via [updateUserContext] or
  /// the SDK's identify() — both round-trip through here.
  Map<String, Object?> userContext;

  // ── Hot reloads from remote config ─────────────────────────────────────

  /// Replace the convention kind → event name map (e.g. after remote config
  /// fetch). Existing entries are dropped.
  void setEventNames(Map<String, String> next) {
    _eventNames = Map<String, String>.from(next);
    debugPrint('[unitrack_snowplow] event_names updated: ${_eventNames.length} entries');
  }

  /// Replace the auto-attach entity map (entity short name → iglu URI).
  void setEntities(Map<String, String> next) {
    _entities = Map<String, String>.from(next);
    debugPrint('[unitrack_snowplow] entities updated: ${_entities.length} entries');
  }

  /// Update the user-context entity values at runtime (e.g. after login).
  void updateUserContext(Map<String, Object?> ctx) {
    userContext = Map<String, Object?>.from(ctx);
  }

  /// Apply Snowplow TrackerConfiguration flags from remote config. Any key
  /// NOT in [overrides] keeps its current value. Rebuilds the tracker because
  /// Snowplow's TrackerConfiguration is immutable after createTracker.
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

  SnowplowTracker? _tracker;

  /// Cached snapshot of `UniTrack.applicationContext()` (bundle/version/
  /// device_name/...). Loaded at init + after each setUser call. Static-ish
  /// values — refreshing per-event would force every track() async. iOS +
  /// Android providers do the same: sync getter, value cached in native side.
  Map<String, Object?> _appCtxCache = const {};

  /// Cached current session_id. Updated at init + onTrack hooks. The C++ core
  /// owns rotation; we mirror the value here so `_buildContexts` stays sync.
  String _sessionIdCache = '';

  Future<void> _refreshAppCtxCache() async {
    try {
      _appCtxCache = await UniTrack.instance.applicationContext();
    } catch (_) {
      _appCtxCache = const {};
    }
  }

  Future<void> _refreshSessionCache() async {
    try {
      _sessionIdCache = await UniTrack.instance.currentSessionId();
    } catch (_) {
      _sessionIdCache = '';
    }
  }

  @override
  Future<void> init() async {
    if (endpoint.isEmpty) {
      debugPrint('[unitrack_snowplow] empty endpoint — provider disabled');
      return;
    }
    await _rebuildTracker();
    // Warm caches AFTER tracker so first event already has full contexts.
    await _refreshAppCtxCache();
    await _refreshSessionCache();
    debugPrint('[unitrack_snowplow] tracker ready ($endpoint, appId=$appId, '
        'vendor=${igluVendor ?? "—"}, version=$defaultVersion, '
        'entities=${_entities.keys.toList()..sort()}, '
        'app_ctx_keys=${_appCtxCache.keys.toList()..sort()}, '
        'session_id=$_sessionIdCache)');
  }

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

  // ── Convention schema/entity plumbing ──────────────────────────────────

  String? _schemaFor(String eventName) {
    final vendor = igluVendor;
    if (vendor == null || vendor.isEmpty) {
      debugPrint('[unitrack_snowplow] no iglu_vendor in portal config — "$eventName" dropped');
      return null;
    }
    return 'iglu:$vendor/$eventName/jsonschema/$defaultVersion';
  }

  /// Accept any of these inputs from portal entity config and return a
  /// well-formed iglu URI. Defensive — UI guides operator to type a short
  /// name, but legacy configs may carry a full URI.
  ///
  ///   "user_context"
  ///     → iglu:<vendor>/user_context/jsonschema/<defaultVersion>
  ///   "vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0"
  ///     → iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0
  ///   "iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0"
  ///     → unchanged
  String? _normalizeEntityURI(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('iglu:')) return s;
    if (s.contains('/')) return 'iglu:$s';
    final vendor = igluVendor;
    if (vendor == null || vendor.isEmpty) return null;
    return 'iglu:$vendor/$s/jsonschema/$defaultVersion';
  }

  /// Convention kind → event name override, falling back to the SDK-built-in
  /// default the helper passes in.
  String _eventName(String kind, String fallback) {
    final v = _eventNames[kind];
    return (v == null || v.isEmpty) ? fallback : v;
  }

  /// Map a raw event name from the SDK auto-capture path to a convention
  /// kind. Returns null when the event isn't recognised — those go out under
  /// their own name (legacy behavior).
  ///
  /// `click`           → kind `click` (auto-tap swizzler)
  /// `screen_load_completed` / `screen_viewed` / `screen_exited` → `screen_view`
  /// `crash`           → kind `crash` (recovered + dart-side errors)
  /// `network_request` → kind `api` (URLProtocol auto-capture)
  /// `session_started` / `session_ended` → kind `session`
  String? _kindForRawEvent(String raw) {
    switch (raw) {
      case 'click':
        return 'click';
      case 'screen_load_completed':
      case 'screen_viewed':
      case 'screen_exited':
      case 'screen_view':
        return 'screen_view';
      case 'crash':
      case 'application_error':
        return 'crash';
      case 'network_request':
        return 'api';
      case 'session_started':
      case 'session_ended':
        return 'session';
    }
    return null;
  }

  String _defaultEventNameForKind(String kind) {
    switch (kind) {
      case 'click':       return 'event_click';
      case 'result':      return 'event_result';
      case 'screen_view': return 'event_screen_view';
      case 'crash':       return 'event_crash';
      case 'api':         return 'event_api';
      case 'session':     return 'event_session';
    }
    return kind;
  }

  /// Build the entity list for one event:
  ///   1. user_context — built from [userContext] (if entities map has it)
  ///   2. core_action  — built from event meta  (if entities map has it)
  ///   3. extra        — anything the caller passed via extraContexts
  /// Any other entity short-name registered in `_entities` is reserved for
  /// the caller to pass via extraContexts.
  List<SelfDescribing> _buildContexts({
    required String eventName,
    String? screen,
    String? elementKey,
    List<SelfDescribing>? extra,
    bool skipGlobalContexts = false,
  }) {
    final out = <SelfDescribing>[];
    if (!skipGlobalContexts) {
      final userRaw = _entities['user_context'];
      if (userRaw != null && userContext.isNotEmpty) {
        final uri = _normalizeEntityURI(userRaw);
        if (uri != null) {
          out.add(SelfDescribing(
            schema: uri,
            data: userContext.map((k, v) => MapEntry(k, v ?? '')),
          ));
        }
      }
      final coreRaw = _entities['core_action'];
      if (coreRaw != null) {
        final uri = _normalizeEntityURI(coreRaw);
        if (uri != null) {
          // core_action carries event meta only — the business name lives in
          // `event.data.event_name`, not duplicated here.
          final now = DateTime.now().toUtc().toIso8601String();
          final data = <String, Object?>{
            'action_name': eventName,
            'timestamp':   now,
            // start_time mirrors iOS — the event was created on the client at
            // this instant. Kept alongside `timestamp` so existing downstream
            // queries don't break.
            'start_time':  now,
          };
          if (screen != null && screen.isNotEmpty)         data['screen'] = screen;
          if (elementKey != null && elementKey.isNotEmpty) data['element_key'] = elementKey;
          // session_id — single join key shared với Portal + custom HTTP
          // providers. C++ core đã stamp lên event.data; mirror vào entity để
          // operator filter Snowplow theo session_id một bước.
          if (_sessionIdCache.isNotEmpty) data['session_id'] = _sessionIdCache;
          out.add(SelfDescribing(
            schema: uri,
            data: data.map((k, v) => MapEntry(k, v ?? '')),
          ));
        }
      }
      // application_context — built from cached UniTrack.applicationContext()
      // (bundle / version / device_name / platform / network / ...). Parity
      // với iOS + Android Snowplow providers; the integrator only registers
      // the schema in portal entities map.
      final appRaw = _entities['application_context'];
      if (appRaw != null && _appCtxCache.isNotEmpty) {
        final uri = _normalizeEntityURI(appRaw);
        if (uri != null) {
          out.add(SelfDescribing(
            schema: uri,
            data: _appCtxCache.map((k, v) => MapEntry(k, v ?? '')),
          ));
        }
      }
    }
    if (extra != null) out.addAll(extra);
    return out;
  }

  /// Strip internal-only keys (anything starting with `_`) before they reach
  /// the SelfDescribing data field.
  Map<String, Object?> _cleanedData(Map<String, Object?> props) {
    final out = <String, Object?>{};
    for (final e in props.entries) {
      if (e.key.startsWith('_')) continue;
      out[e.key] = e.value;
    }
    return out;
  }

  // ── Logging (parity with iOS NSLog + Android Log.i) ────────────────────

  bool logEvents = true;

  void _logSnowplow({
    required String name,
    required String schema,
    required Map<String, Object?> data,
    required List<SelfDescribing> contexts,
  }) {
    if (!logEvents) return;
    final payload = {
      'endpoint': endpoint,
      'method': 'trackSelfDescribingEvent',
      'event':   {'schema': schema, 'data': data},
      'contexts': contexts.map((c) => {
        'schema': c.schema,
        'data':   c.data,
      }).toList(),
    };
    final s = const JsonEncoder.withIndent('  ').convert(payload);
    debugPrint('─── Snowplow Tracking ───  (convention event="$name")');
    for (final line in s.split('\n')) debugPrint(line);
  }

  // ── Convention helpers (app-facing) ────────────────────────────────────

  /// Self-describing event with the caller-built schema. Skips the convention
  /// name resolution; used by [trackingScreenView] / [trackingCrash] / app
  /// code that already knows its iglu URI.
  void trackSelfDescribing({
    required String schema,
    required String nameHint,
    required Map<String, Object?> data,
    String? screen,
    String? elementKey,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final t = _tracker;
    if (t == null) return;
    final contexts = _buildContexts(
      eventName: nameHint, screen: screen, elementKey: elementKey,
      extra: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
    t.track(SelfDescribing(schema: schema, data: data), contexts: contexts);
    _logSnowplow(name: nameHint, schema: schema, data: data, contexts: contexts);
    _mirrorToPortal(nameHint, {
      '_sp_type': 'self_describing',
      '_sp_schema': schema,
      ...data,
    });
  }

  /// Click convention — kind=`click`, default name `event_click`.
  /// `elementKey` doubles as the business name for the click (e.g.
  /// `camera_item_selected`, `notif_request_permission`). It's emitted in
  /// the event payload as `event_name` so the same iglu schema carries the
  /// specific business signal in addition to the generic shape.
  void trackingClickEvent({
    required String elementKey,
    String? label,
    String? screen,
    Map<String, Object?>? data,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final name = _eventName('click', 'event_click');
    final schema = _schemaFor(name);
    if (schema == null) return;
    final payload = <String, Object?>{'event_name': elementKey};
    if (label != null)  payload['label']  = label;
    if (screen != null) payload['screen'] = screen;
    if (data != null)   payload.addAll(data);
    trackSelfDescribing(
      schema: schema, nameHint: name, data: payload,
      screen: screen, elementKey: elementKey,
      extraContexts: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
  }

  /// Result convention — kind=`result`, default name `event_result`.
  /// `action` is the business event (e.g. `camera_pairing_completed`); it's
  /// emitted as `event_name` in the payload so the iglu schema sees both
  /// the generic shape and the specific business signal.
  void trackingResultEvent({
    required String action,
    required String status,
    String? errorCode,
    String? errorMessage,
    int? durationMs,
    Map<String, Object?>? data,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final name = _eventName('result', 'event_result');
    final schema = _schemaFor(name);
    if (schema == null) return;
    final payload = <String, Object?>{
      'event_name': action,
      'status':     status,
    };
    if (errorCode    != null) payload['error_code']    = errorCode;
    if (errorMessage != null) payload['error_message'] = errorMessage;
    if (durationMs   != null) payload['duration_ms']   = durationMs;
    if (data != null) payload.addAll(data);
    trackSelfDescribing(
      schema: schema, nameHint: name, data: payload,
      extraContexts: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
  }

  /// Screen-view convention — kind=`screen_view`, default name
  /// `event_screen_view`. Also fires Snowplow's native ScreenView so the
  /// session is correctly sliced by screen.
  ///
  /// `businessName` lets the caller stamp a specific business event into
  /// the payload (e.g. `screen_load_completed`, `screen_viewed`,
  /// `screen_exited`) without changing the iglu schema URI — the schema
  /// stays the generic screen_view shape; the business signal lives in
  /// `event.data.event_name`. Defaults to the resolved convention name
  /// when omitted.
  void trackingScreenView({
    required String screenName,
    String? businessName,
    String? fromScreen,
    Map<String, Object?>? data,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final name = _eventName('screen_view', 'event_screen_view');
    final schema = _schemaFor(name);
    if (schema == null) return;
    final payload = <String, Object?>{
      'event_name': businessName ?? name,
      'screen':     screenName,
    };
    if (fromScreen != null) payload['from_screen'] = fromScreen;
    if (data != null) payload.addAll(data);
    trackSelfDescribing(
      schema: schema, nameHint: name, data: payload, screen: screenName,
      extraContexts: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
    _tracker?.track(ScreenView(name: screenName));
  }

  /// API convention — kind=`api`, default name `event_api`. Models any
  /// network-style timing (HTTP, RTSP, gRPC). `businessName` lets the
  /// caller stamp a business signal (e.g. `camera_stream_first_frame`,
  /// `camera_notification_delivered`) into `event.data.event_name`.
  void trackingAPI({
    required String url,
    required String method,
    required int status,
    required int durationMs,
    String? businessName,
    Map<String, Object?>? data,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final name = _eventName('api', 'event_api');
    final schema = _schemaFor(name);
    if (schema == null) return;
    final payload = <String, Object?>{
      'event_name':  businessName ?? name,
      'url': url, 'method': method, 'status': status, 'duration_ms': durationMs,
    };
    if (data != null) payload.addAll(data);
    trackSelfDescribing(
      schema: schema, nameHint: name, data: payload,
      extraContexts: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
  }

  /// Crash convention — kind=`crash`, default name `event_crash`. Use for
  /// non-fatal exceptions the app wants to surface explicitly. Hard crashes
  /// caught by the SDK's signal handler flow through `track('crash', …)`.
  /// `businessName` stamps a business signal (e.g. `application_error`,
  /// `stream_decoder_error`) into `event.data.event_name`.
  void trackingCrash({
    required String message,
    String? stack,
    String? screen,
    String? businessName,
    Map<String, Object?>? data,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final name = _eventName('crash', 'event_crash');
    final schema = _schemaFor(name);
    if (schema == null) return;
    final payload = <String, Object?>{
      'event_name': businessName ?? name,
      'message':    message,
    };
    if (stack  != null) payload['stack']  = stack;
    if (screen != null) payload['screen'] = screen;
    if (data != null) payload.addAll(data);
    trackSelfDescribing(
      schema: schema, nameHint: name, data: payload, screen: screen,
      extraContexts: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
  }

  /// Session-lifecycle convention — kind=`session`, default name
  /// `event_session`. `action` doubles as the business event signal
  /// (e.g. `session_started`, `session_ended`) — emitted as `event_name`
  /// in the payload.
  void trackingSession({
    required String action,
    String? reason,
    int? durationMs,
    String? source,
    Map<String, Object?>? data,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final name = _eventName('session', 'event_session');
    final schema = _schemaFor(name);
    if (schema == null) return;
    final payload = <String, Object?>{'event_name': action};
    if (reason     != null) payload['reason']      = reason;
    if (durationMs != null) payload['duration_ms'] = durationMs;
    if (source     != null) payload['source']      = source;
    if (data != null) payload.addAll(data);
    trackSelfDescribing(
      schema: schema, nameHint: name, data: payload,
      extraContexts: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
  }

  /// Custom convention kind — looks up `eventNames[kind]` (falls back to
  /// [kind] itself) then builds the schema URI from the configured vendor.
  /// Used by code-generated `trackingXxx()` helpers and by app code that
  /// wants to register a project-specific kind without editing the SDK.
  void trackingCustomEvent({
    required String kind,
    Map<String, Object?>? data,
    String? screen,
    String? elementKey,
    List<SelfDescribing>? extraContexts,
    bool skipGlobalContexts = false,
  }) {
    final name = _eventName(kind, kind);
    final schema = _schemaFor(name);
    if (schema == null) return;
    trackSelfDescribing(
      schema: schema, nameHint: name,
      data: data ?? const {}, screen: screen, elementKey: elementKey,
      extraContexts: extraContexts, skipGlobalContexts: skipGlobalContexts,
    );
  }

  // ── AnalyticsProvider protocol ─────────────────────────────────────────

  @override
  Future<void> setUser(String? userId, Map<String, Object?> traits) async {
    _tracker?.setUserId(userId);
    if (userId != null) userContext['user_id'] = userId;
    for (final e in traits.entries) {
      userContext[e.key] = e.value;
    }
  }

  @override
  void track(String name, Map<String, Object?> properties) {
    final t = _tracker;
    if (t == null) return;
    // Session can rotate mid-run (timeout / explicit rotateSession). Refresh
    // cache fire-and-forget — first event after rotation may use the stale
    // id, but subsequent events catch up. Acceptable trade-off vs making the
    // hot path async.
    unawaited(_refreshSessionCache());
    // Caller already fired the event into Snowplow directly and only wants
    // the portal mirror — drop the Snowplow leg here.
    if (properties['_skip_snowplow'] == true) {
      _mirrorToPortal(name, {
        '_sp_type': 'self_describing', '_sp_skipped': true,
        ..._cleanedData(properties),
      });
      return;
    }
    // Convention-kind routing. The 6 built-in kinds (click / result /
    // screen_view / crash / api / session) resolve via portal `event_names`
    // so the iglu schema becomes the wire name (e.g. click → event_click).
    // The original raw name is preserved as `event_name` in the payload so a
    // single iglu schema carries both the generic shape and the specific
    // business signal. Non-kind names (e.g. `screen_load_completed`) still
    // dispatch through the matching kind — see _kindForRawEvent.
    final kind = _kindForRawEvent(name);
    final resolvedName = (kind != null)
        ? _eventName(kind, _defaultEventNameForKind(kind))
        : name;
    final schema = _schemaFor(resolvedName);
    if (schema != null) {
      final screen     = properties['screen']?.toString() ??
                         properties['screen_name']?.toString();
      final elementKey = properties['element_key']?.toString();
      // Drop the SDK-internal `element_key` from the event payload when it
      // duplicates the business signal we're stamping in event_name; keeps
      // the payload clean while core_action still carries it.
      final cleaned = _cleanedData(properties);
      final data = <String, Object?>{
        if (kind != null) 'event_name': name,
        ...cleaned,
      };
      final contexts = _buildContexts(
        eventName: resolvedName, screen: screen, elementKey: elementKey,
        extra: null, skipGlobalContexts: false,
      );
      t.track(SelfDescribing(schema: schema, data: data), contexts: contexts);
      _logSnowplow(name: resolvedName, schema: schema, data: data, contexts: contexts);
      _mirrorToPortal(resolvedName, {
        '_sp_type': 'self_describing', '_sp_schema': schema, ...data,
      });
      return;
    }
    // No iglu vendor configured → fall back to a Structured event so the
    // collector still receives the event. category=unitrack so the operator
    // can grep for "we forgot to set iglu_vendor" rows on the collector.
    final label    = properties['screen']?.toString() ??
                     properties['screen_name']?.toString();
    final property = properties['element_key']?.toString() ??
                     properties['state']?.toString();
    t.track(
      Structured(
        category: 'unitrack', action: name,
        label: label, property: property,
      ),
    );
    _mirrorToPortal(name, {
      '_sp_type': 'structured',
      '_sp_category': 'unitrack', '_sp_action': name,
      if (label    != null) '_sp_label':    label,
      if (property != null) '_sp_property': property,
      ..._cleanedData(properties),
    });
  }

  @override
  void setScreen(String name) {
    final t = _tracker;
    if (t == null) return;
    final contexts = _buildContexts(
      eventName: name, screen: name, elementKey: null,
      extra: null, skipGlobalContexts: false,
    );
    t.track(ScreenView(name: name), contexts: contexts);
  }

  // ── Portal mirror ──────────────────────────────────────────────────────
  // Same fire-and-forget pattern as FirebaseProvider so the portal sees the
  // event as `provider=snowplow` and the session IDE can show side-by-side.
  void _mirrorToPortal(String name, Map<String, Object?> properties) {
    final ep = portalEndpoint, key = portalApiKey;
    if (ep == null || key == null || ep.isEmpty || key.isEmpty) return;
    final uri = Uri.parse('$ep${ep.contains('?') ? '&' : '?'}provider=snowplow');
    final body = jsonEncode({
      'event_id':   '${DateTime.now().microsecondsSinceEpoch}_$name',
      'event_name': name,
      'timestamp':  DateTime.now().millisecondsSinceEpoch,
      'properties': properties,
    });
    HttpClient().postUrl(uri).then((req) {
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Authorization', 'Bearer $key');
      req.add(utf8.encode(body));
      return req.close();
    }).then((resp) => resp.drain<void>()).catchError((_) {/* best effort */});
  }
}

/// Snowplow TrackerConfiguration flags the developer can toggle. Defaults
/// match Snowplow's recommended mobile setup. Mirrors SnowplowOptions on
/// iOS and Android.
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
