// UniTrack Flutter plugin — Dart public API.
//
// Forwards calls to the iOS / Android native SDK via a MethodChannel.
// Auto-capture is enabled on the native side; the Dart side exposes
// a NavigatorObserver for route tracking and a safe JSON helper.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class UniTrackConfig {
  final String? endpoint;
  final int batchSize;
  final int flushIntervalMs;
  final double samplingRate;
  final bool autoCapture;
  final bool trackScreens;
  final bool trackTaps;
  final bool trackNetwork;

  const UniTrackConfig({
    this.endpoint,
    this.batchSize = 50,
    this.flushIntervalMs = 5000,
    this.samplingRate = 1.0,
    this.autoCapture = true,
    this.trackScreens = true,
    this.trackTaps = true,
    this.trackNetwork = true,
  });

  Map<String, dynamic> toMap() => {
        if (endpoint != null) 'endpoint': endpoint,
        'batchSize': batchSize,
        'flushIntervalMs': flushIntervalMs,
        'samplingRate': samplingRate,
        'autoCapture': autoCapture,
        'trackScreens': trackScreens,
        'trackTaps': trackTaps,
        'trackNetwork': trackNetwork,
      };
}

class UniTrack {
  UniTrack._();
  static final UniTrack instance = UniTrack._();

  static const MethodChannel _channel = MethodChannel('unitrack');
  bool _initialized = false;

  Future<void> initialize(String apiKey, {UniTrackConfig? config}) async {
    if (_initialized) return;
    final cfg = config ?? const UniTrackConfig();
    await _channel.invokeMethod('initialize', {
      'apiKey': apiKey,
      'config': jsonEncode(cfg.toMap()),
    });
    _initialized = true;
  }

  Future<void> identify(String userId, {Map<String, Object?>? traits}) =>
      _channel.invokeMethod('identify', {
        'userId': userId,
        'traits': jsonEncode(traits ?? {}),
      });

  Future<void> reset() => _channel.invokeMethod('reset');

  Future<void> track(String event,
          {Map<String, Object?>? properties}) =>
      _channel.invokeMethod('track', {
        'event': event,
        'props': jsonEncode(properties ?? {}),
      });

  Future<void> setScreen(String name) =>
      _channel.invokeMethod('setScreen', {'name': name});

  Future<void> flush() => _channel.invokeMethod('flush');

  Future<void> setEnabled(bool enabled) =>
      _channel.invokeMethod('setEnabled', {'enabled': enabled});
}

/// NavigatorObserver — auto-tracks Flutter routes.
///
/// Usage:
///   MaterialApp(
///     navigatorObservers: [UniTrackNavigatorObserver()],
///     ...
///   )
class UniTrackNavigatorObserver extends NavigatorObserver {
  String? _lastRoute;

  void _track(Route<dynamic>? r) {
    if (r is! PageRoute) return;
    final name = r.settings.name ?? r.runtimeType.toString();
    if (name == _lastRoute) return;
    _lastRoute = name;
    UniTrack.instance.setScreen(name);
  }

  @override
  void didPush(Route route, Route? previousRoute)         => _track(route);
  @override
  void didReplace({Route? newRoute, Route? oldRoute})     => _track(newRoute);
  @override
  void didPop(Route route, Route? previousRoute)          => _track(previousRoute);
}

/// Safely parse JSON, reporting failures to UniTrack.
T? safeJsonParse<T>(String targetType, String raw) {
  try {
    return jsonDecode(raw) as T;
  } catch (e, st) {
    UniTrack.instance.track('json_parse_error', properties: {
      'type': targetType,
      'error': '${e.runtimeType}: $e',
      'stack': st.toString().split('\n').take(8).join('\n'),
      'data_preview': raw.length > 200 ? raw.substring(0, 200) : raw,
    });
    if (kDebugMode) rethrow;
    return null;
  }
}
