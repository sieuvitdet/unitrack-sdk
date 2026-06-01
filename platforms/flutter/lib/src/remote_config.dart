// UniTrackRemoteConfig — fetches the app's tracking config from the portal at
// startup (GET {portal}/config, auth = api_key), so endpoints, providers,
// schemas and event-rewrite rules can change WITHOUT rebuilding the app.
//
// Resilient: on success caches in-memory (and the app may persist it); on
// failure/timeout returns the last value or a built-in default — launch never
// blocks. Dependency-free (uses dart:io HttpClient).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../unitrack.dart';

class UniTrackRemoteConfig {
  UniTrackRemoteConfig(this.raw);

  /// The decoded JSON the portal returned (or default/cached).
  final Map<String, dynamic> raw;

  int get version => (raw['version'] as num?)?.toInt() ?? 0;
  String? get endpoint => raw['endpoint'] as String?;
  Map<String, dynamic> get sdkConfig => _obj(raw['sdk_config']);
  Map<String, dynamic> get snowplow => _obj(raw['snowplow']);
  Map<String, dynamic> get firebase => _obj(raw['firebase']);
  List<dynamic> get eventRegistry => (raw['event_registry'] as List?) ?? const [];
  List<dynamic> get rules => (raw['rules'] as List?) ?? const [];
  /// W3C distributed-tracing settings (may be absent — treat as disabled).
  Map<String, dynamic> get tracing => _obj(raw['tracing']);

  static Map<String, dynamic> _obj(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  /// Apply the tracing block (if present) to UniTrack so the HTTP interceptor
  /// picks it up. Safe no-op when the portal didn't send a `tracing` section.
  void applyTracing() {
    if (tracing.isEmpty) return;
    UniTrack.instance.setTracing(
      enabled: tracing['enabled'] == true,
      headerName: (tracing['header_name'] as String?) ?? 'traceparent',
      allowlistHosts: ((tracing['allowlist_hosts'] as List?) ?? const [])
          .whereType<String>().toList(),
      sampled: tracing['sampled'] != false,   // default true
    );
  }

  /// Map of UniTrack event name → iglu schema URI for Snowplow self-describing
  /// events. Sourced from `snowplow.schemas` on the wire — an empty map (or
  /// missing block) means everything stays Structured.
  ///
  /// Apps wire it like:
  ///   final cfg = await UniTrackRemoteConfig.fetch(...);
  ///   snowplowProvider.setSchemas(cfg.snowplowSchemas);
  Map<String, String> get snowplowSchemas {
    final raw = snowplow['schemas'];
    if (raw is Map) {
      return {
        for (final e in raw.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    }
    return const {};
  }

  /// Default iglu schema URI for an event name — used by the portal when
  /// auto-seeding the schemas map. Pattern matches the FTel convention
  ///   iglu:vn.fpt.ftel.snowplow/<event_name>/jsonschema/1-0-0
  /// Apps can override per-event via the snowplow.schemas map.
  static String defaultIgluSchema(String eventName, {String version = '1-0-0'}) {
    return 'iglu:vn.fpt.ftel.snowplow/$eventName/jsonschema/$version';
  }

  /// Raw `snowplow.options` map from the portal (Snowplow TrackerConfiguration
  /// flags: base64Encoding, platformContext, applicationContext, sessionContext,
  /// screenContext, lifecycleAutotracking, screenEngagementAutotracking).
  ///
  /// Returns an empty map when the operator didn't override anything — callers
  /// fall back to their own defaults (matching Snowplow's recommended setup).
  /// Defensive read: each value is coerced to bool only when explicitly true /
  /// false on the wire so a typo doesn't silently flip a flag.
  Map<String, bool> get snowplowOptions {
    final raw = snowplow['options'];
    if (raw is! Map) return const {};
    final out = <String, bool>{};
    for (final e in raw.entries) {
      if (e.key is String && (e.value == true || e.value == false)) {
        out[e.key as String] = e.value as bool;
      }
    }
    return out;
  }

  /// Map config rules → SDK rules and install them on UniTrack.
  List<UniTrackEventRule> toEventRules() => rules.map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        return UniTrackEventRule(
          matchEvent: m['match_event'] as String,
          matchScreen: m['match_screen'] as String?,
          matchElementKey: m['match_element_key'] as String?,
          toName: m['to_name'] as String,
          addProps: (m['add_props'] is Map)
              ? Map<String, Object?>.from(m['add_props'] as Map)
              : const {},
        );
      }).toList();

  // In-memory cache (per api_key). The app can persist `raw` itself if desired.
  static final Map<String, Map<String, dynamic>> _cache = {};

  /// Fetch config from the portal. Always completes with a usable config
  /// (fresh, cached, or [fallback]/default). Never throws.
  ///
  /// [flavor] selects a per-build override block on the portal (dev /
  /// staging / beta / production). Apps usually wire this from their build
  /// flavor (e.g. `String.fromEnvironment('FLAVOR')` or a `--dart-define`).
  static Future<UniTrackRemoteConfig> fetch({
    required String apiKey,
    required String configURL,
    String? flavor,
    Duration timeout = const Duration(seconds: 3),
    Map<String, dynamic>? fallback,
  }) async {
    // Append ?flavor=... — Uri.replace handles existing query strings cleanly.
    Uri url = Uri.parse(configURL);
    if (flavor != null && flavor.isNotEmpty) {
      url = url.replace(queryParameters: {
        ...url.queryParameters,
        'flavor': flavor,
      });
    }
    try {
      final client = HttpClient()..connectionTimeout = timeout;
      final req = await client.getUrl(url).timeout(timeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      // Header form too — survives a CDN that strips query strings.
      if (flavor != null && flavor.isNotEmpty) {
        req.headers.set('X-UniTrack-Flavor', flavor);
      }
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final json = Map<String, dynamic>.from(jsonDecode(body) as Map);
        _cache[apiKey] = json;
        client.close();
        return UniTrackRemoteConfig(json);
      }
      client.close();
    } catch (_) {
      // fall through to cached / fallback / default
    }
    return UniTrackRemoteConfig(
        _cache[apiKey] ?? fallback ?? _builtinDefault());
  }

  static Map<String, dynamic> _builtinDefault() => {
        'version': 0,
        'endpoint': 'https://mobix.asia/event-tracking-mobile/v1/events',
        'sdk_config': {
          'batchSize': 10, 'flushIntervalMs': 3000, 'autoCapture': true,
          'trackScreens': true, 'trackTaps': true, 'trackNetwork': true,
        },
        'snowplow': {'enabled': false},
        'firebase': {'enabled': false},
        'event_registry': [],
        'rules': [],
      };
}
