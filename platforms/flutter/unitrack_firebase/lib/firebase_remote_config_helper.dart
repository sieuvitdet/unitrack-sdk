// UniTrackFirebaseRemoteConfig — Firebase Remote Config wrapper.
//
// UniTrack exposes a unified [UniTrack.instance.getRemoteValue<T>] that
// resolves in this order:
//   1. Portal `sdk_config.custom_values[key]` (operator-edited, shipped via
//      the SDK config blob)
//   2. Firebase Remote Config (this helper, if [activate()] was called)
//   3. Caller's defaultValue
//
// This helper is opt-in: call [activate(minimumFetchInterval: …)] once at
// startup AFTER `Firebase.initializeApp()`. The native side already polls
// custom_values; this just plugs Firebase RC into the same resolver.
//
// Usage:
//
//   await Firebase.initializeApp();
//   await UniTrackFirebaseRemoteConfig.activate(
//     defaults: {'feature_camera_grid': false, 'home_banner_copy': 'Welcome'},
//     minimumFetchInterval: const Duration(hours: 1),
//   );
//
//   final on = await UniTrack.instance.getRemoteValue<bool>(
//     'feature_camera_grid', defaultValue: false);
//
// The MethodChannel `getRemoteValue` plumbed in Phase 1 hits the NATIVE
// Firebase RC binding (FirebaseProvider's `RemoteValueProvider` conformance
// on iOS / Android). Flutter Remote Config sits in the Dart isolate, so we
// register an in-process resolver below that the Dart layer prefers before
// falling back to the platform channel.

import 'package:firebase_remote_config/firebase_remote_config.dart';

class UniTrackFirebaseRemoteConfig {
  UniTrackFirebaseRemoteConfig._();

  static FirebaseRemoteConfig? _rc;
  static bool _activated = false;

  /// Whether [activate] completed at least once. Apps can use this to gate
  /// UI that only makes sense after RC has run (vd "Show experiment X").
  static bool get isActivated => _activated;

  /// Fetch + activate Remote Config with sensible defaults.
  ///
  /// • [minimumFetchInterval] — Firebase throttle. 1h is fine for most apps;
  ///   shorten during a roll-out and re-tighten before release.
  /// • [fetchTimeout] — how long to wait before falling back to defaults.
  /// • [defaults] — local fallback values when no fetched value exists for
  ///   a key. Same shape Firebase RC accepts (String/num/bool).
  ///
  /// Safe to call multiple times — subsequent calls re-fetch + re-activate.
  static Future<void> activate({
    Map<String, dynamic> defaults = const {},
    Duration minimumFetchInterval = const Duration(hours: 1),
    Duration fetchTimeout = const Duration(seconds: 10),
  }) async {
    final rc = _rc ??= FirebaseRemoteConfig.instance;
    await rc.setConfigSettings(RemoteConfigSettings(
      fetchTimeout: fetchTimeout,
      minimumFetchInterval: minimumFetchInterval,
    ));
    if (defaults.isNotEmpty) {
      await rc.setDefaults(defaults);
    }
    try {
      await rc.fetchAndActivate();
    } catch (_) {
      // Network down / quota exhausted — defaults still apply, just no fresh
      // values. Don't throw to the host app; let it use whatever was cached.
    }
    _activated = true;
  }

  /// Synchronous lookup. Returns null if [activate] hasn't been called or
  /// the key has no value AND no default. Used internally by UniTrack's
  /// getRemoteValue resolver chain.
  static T? lookup<T>(String key) {
    final rc = _rc;
    if (rc == null) return null;
    final v = rc.getValue(key);
    switch (T) {
      case String:
        final s = v.asString();
        return s.isEmpty ? null : s as T;
      case bool:
        return v.asBool() as T;
      case int:
        return v.asInt() as T;
      case double:
        return v.asDouble() as T;
      default:
        return null;
    }
  }

  /// Convenience getters mirroring Firebase's typed accessors. App code can
  /// call these directly when it specifically wants RC (not the unified
  /// UniTrack resolver chain).
  static String getString(String key, {String defaultValue = ''}) =>
      lookup<String>(key) ?? defaultValue;
  static bool getBool(String key, {bool defaultValue = false}) =>
      lookup<bool>(key) ?? defaultValue;
  static int getInt(String key, {int defaultValue = 0}) =>
      lookup<int>(key) ?? defaultValue;
  static double getDouble(String key, {double defaultValue = 0.0}) =>
      lookup<double>(key) ?? defaultValue;
}
