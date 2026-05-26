// unitrack_firebase — forwards every UniTrack event to Firebase Analytics.
//
// Prerequisites (standard FlutterFire setup — done by the app, not this pkg):
//   • android/app/google-services.json present + google-services gradle plugin
//   • ios/Runner/GoogleService-Info.plist added to the Runner target
//
// Usage:
//   UniTrack.instance.addProvider(FirebaseProvider());
//   await UniTrack.instance.initialize(apiKey);
//
// Every UniTrack event becomes a Firebase logEvent. Firebase imposes strict
// naming rules (event/param names: <=40 chars, alphanumeric + underscore,
// must start with a letter; values: String/num/bool only), so names and
// parameters are sanitized — a warning is logged whenever a name is altered.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:unitrack/unitrack.dart';

class FirebaseProvider extends AnalyticsProvider {
  /// [portalEndpoint] + [portalApiKey]: optional. When both are set, every event
  /// forwarded to Firebase is ALSO sent as a copy to the UniTrack portal tagged
  /// provider=firebase, so the portal can show what went to Firebase. (Firebase's
  /// own pipeline can't be proxied, so this copy is how the portal "sees" it.)
  /// [superProperties] are merged into EVERY Firebase event's parameters.
  /// [userProperties] are set as Firebase user properties at init (audiences).
  FirebaseProvider({
    this.portalEndpoint,
    this.portalApiKey,
    Map<String, Object?> superProperties = const {},
    Map<String, Object?> userProperties = const {},
  })  : _superProps = Map.of(superProperties),
        _userProps = Map.of(userProperties);

  final String? portalEndpoint;
  final String? portalApiKey;
  final Map<String, Object?> _superProps;
  final Map<String, Object?> _userProps;

  FirebaseAnalytics? _fa;

  /// Add/replace a super property at runtime (applies to subsequent events).
  void setSuperProperty(String key, Object? value) => _superProps[key] = value;
  void removeSuperProperty(String key) => _superProps.remove(key);
  /// Set a Firebase user property at runtime.
  void setUserProperty(String key, String? value) =>
      _fa?.setUserProperty(name: _sanitizeName(key), value: value);

  @override
  Future<void> init() async {
    // initializeApp reads google-services.json / GoogleService-Info.plist.
    // If the app already called it, Firebase is idempotent enough that we
    // guard against the duplicate-app error.
    try {
      await Firebase.initializeApp();
    } catch (e) {
      // Likely already initialized by the host app — that's fine.
      debugPrint('[unitrack_firebase] initializeApp note: $e');
    }
    _fa = FirebaseAnalytics.instance;
    // Apply initial Firebase user properties (audiences/segmentation).
    _userProps.forEach((k, v) {
      _fa?.setUserProperty(name: _sanitizeName(k), value: v?.toString());
    });
    debugPrint('[unitrack_firebase] Firebase Analytics ready');
  }

  @override
  void track(String name, Map<String, Object?> properties) {
    final fa = _fa;
    if (fa == null) return;
    // Merge super properties under the event's own (event props win).
    final merged = <String, Object?>{..._superProps, ...properties};
    fa.logEvent(
      name: _sanitizeName(name),
      parameters: _sanitizeParams(merged),
    );
    _mirrorToPortal(name, merged);
  }

  // Send a fire-and-forget copy to the portal, tagged provider=firebase.
  void _mirrorToPortal(String name, Map<String, Object?> properties) {
    final ep = portalEndpoint, key = portalApiKey;
    if (ep == null || key == null || ep.isEmpty || key.isEmpty) return;
    final uri = Uri.parse('$ep${ep.contains('?') ? '&' : '?'}provider=firebase');
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
    final fa = _fa;
    if (fa == null) return;
    fa.setUserId(id: userId);
    traits.forEach((k, v) {
      fa.setUserProperty(name: _sanitizeName(k), value: v?.toString());
    });
  }

  @override
  void setScreen(String name) {
    _fa?.logScreenView(screenName: name);
  }

  // --- Firebase naming/value constraints ----------------------------------

  static final RegExp _illegal = RegExp(r'[^a-zA-Z0-9_]');

  /// Firebase event/param names: start with a letter, alphanumeric/underscore,
  /// max 40 chars. Replace illegal chars with '_' and warn if changed.
  String _sanitizeName(String name) {
    var s = name.replaceAll(_illegal, '_');
    if (s.isNotEmpty && !RegExp(r'^[a-zA-Z]').hasMatch(s)) s = 'e_$s';
    if (s.length > 40) s = s.substring(0, 40);
    if (s != name) debugPrint('[unitrack_firebase] name "$name" -> "$s"');
    return s;
  }

  /// Firebase parameter values must be String/num/bool. Coerce everything else
  /// (maps/lists) to their JSON-ish string form, and clamp string length (100).
  Map<String, Object> _sanitizeParams(Map<String, Object?> props) {
    final out = <String, Object>{};
    props.forEach((k, v) {
      if (v == null) return;
      final key = _sanitizeName(k);
      Object value;
      if (v is num || v is bool || v is String) {
        value = v;
      } else {
        value = v.toString();
      }
      if (value is String && value.length > 100) {
        value = value.substring(0, 100);
      }
      out[key] = value;
    });
    return out;
  }
}
