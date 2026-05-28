// UniTrack Flutter plugin — Dart public API.
//
// Forwards calls to the iOS / Android native SDK via a MethodChannel.
// Auto-capture is enabled on the native side; the Dart side exposes
// a NavigatorObserver for route tracking and a safe JSON helper.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpOverrides;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'src/auto_capture.dart' show installUniTrackHttpAutoCapture, UniTrackBodyCapture;
import 'src/analytics_provider.dart';

// Dart-layer auto-capture (tap + screen + network). See src/auto_capture.dart.
export 'src/auto_capture.dart'
    show UniTrackTapObserver, UniTrackRouteObserver, LastTap, UniTrackBodyCapture;
// Extension point for third-party providers (Snowplow, Firebase). The provider
// implementations live in separate packages (unitrack_snowplow, …).
export 'src/analytics_provider.dart' show AnalyticsProvider;
// Remote config fetcher (Phase 1+2): app pulls endpoint/providers/rules at start.
export 'src/remote_config.dart' show UniTrackRemoteConfig;

class UniTrackConfig {
  final String? endpoint;
  final int batchSize;
  final int flushIntervalMs;
  final double samplingRate;
  final bool autoCapture;
  final bool trackScreens;
  final bool trackTaps;
  final bool trackNetwork;

  /// Emit session_start/session_end boundaries so the portal can reconstruct
  /// each session's journey.
  final bool journeyCapture;

  /// Inactivity/background window (ms) after which a session is closed.
  final int sessionTimeoutMs;

  const UniTrackConfig({
    this.endpoint,
    this.batchSize = 50,
    this.flushIntervalMs = 5000,
    this.samplingRate = 1.0,
    this.autoCapture = true,
    this.trackScreens = true,
    this.trackTaps = true,
    this.trackNetwork = true,
    this.journeyCapture = true,
    this.sessionTimeoutMs = 1800000,
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
        'journeyCapture': journeyCapture,
        'sessionTimeoutMs': sessionTimeoutMs,
      };
}

/// A config-driven rewrite rule: when an auto-captured event matches, the SDK
/// renames it to [toName] and merges [addProps]. Built from the remote config.
class UniTrackEventRule {
  final String matchEvent;
  final String? matchScreen;
  final String? matchElementKey;
  final String toName;
  final Map<String, Object?> addProps;
  const UniTrackEventRule({
    required this.matchEvent,
    this.matchScreen,
    this.matchElementKey,
    required this.toName,
    this.addProps = const {},
  });
}

class UniTrack {
  UniTrack._();
  static final UniTrack instance = UniTrack._();

  static const MethodChannel _channel = MethodChannel('unitrack');
  bool _initialized = false;
  DateTime? _initAt;

  // Registered third-party providers (Snowplow, Firebase, …). Every event is
  // forwarded to each one. Empty by default — core has zero such dependencies.
  final List<AnalyticsProvider> _providers = [];

  /// Register a provider to also receive every event. Call BEFORE initialize();
  /// if called afterwards, the provider is initialized immediately.
  void addProvider(AnalyticsProvider provider) {
    _providers.add(provider);
    if (_initialized) {
      // Already running — bring this one up now so it doesn't miss events.
      Future(() async {
        try {
          await provider.init();
        } catch (e, s) {
          debugPrint('[UniTrack] provider init failed: $e\n$s');
        }
      });
    }
  }

  // Run [action] against every provider, isolating failures so one bad
  // provider never breaks the main pipeline or the other providers.
  void _forEachProvider(void Function(AnalyticsProvider p) action) {
    for (final p in _providers) {
      try {
        action(p);
      } catch (e) {
        debugPrint('[UniTrack] provider forward failed: $e');
      }
    }
  }

  Future<void> initialize(String apiKey,
      {UniTrackConfig? config, bool captureErrors = true}) async {
    if (_initialized) return;
    final cfg = config ?? const UniTrackConfig();
    await _channel.invokeMethod('initialize', {
      'apiKey': apiKey,
      'config': jsonEncode(cfg.toMap()),
    });
    _initialized = true;
    _initAt = DateTime.now();
    if (captureErrors) _installErrorHandlers();
    // Bring up any providers registered before initialize().
    for (final p in _providers) {
      try {
        await p.init();
      } catch (e, s) {
        debugPrint('[UniTrack] provider init failed: $e\n$s');
      }
    }
  }

  bool _errorHandlersInstalled = false;

  /// Capture uncaught Dart errors and report them as `crash` events.
  ///
  /// IMPORTANT: a Dart `throw` is NOT a native crash (SIGSEGV/SIGABRT) — it is
  /// caught by the Flutter framework and never reaches the native POSIX crash
  /// handler. So to track Flutter-side crashes we must hook Dart's own error
  /// channels: FlutterError.onError (framework/build errors) and
  /// PlatformDispatcher.onError (uncaught async/zone errors).
  void _installErrorHandlers() {
    if (_errorHandlersInstalled) return;
    _errorHandlersInstalled = true;

    final priorFlutterOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _reportCrash(details.exception, details.stack,
          context: details.context?.toString(), fatal: false);
      priorFlutterOnError?.call(details); // keep red-screen / console output
    };

    final priorPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _reportCrash(error, stack, fatal: true);
      return priorPlatformOnError?.call(error, stack) ?? true;
    };
  }

  void _reportCrash(Object error, StackTrace? stack,
      {String? context, bool fatal = true}) {
    final trace = (stack ?? StackTrace.current).toString();
    // A crash within a few seconds of init is almost certainly a launch crash.
    final onLaunch = _initAt != null &&
        DateTime.now().difference(_initAt!) < const Duration(seconds: 5);
    track('crash', properties: {
      'type': error.runtimeType.toString(),
      'message': error.toString(),
      'fatal': fatal,
      'crash_on_launch': onLaunch,
      if (context != null) 'context': context,
      'stack': trace.split('\n').take(20).join('\n'),
      'platform': 'flutter',
    });
    flush(); // best-effort: get it out before the app may go down
  }

  Future<void> identify(String userId, {Map<String, Object?>? traits}) {
    final t = traits ?? const <String, Object?>{};
    _forEachProvider((p) => p.setUser(userId, t));
    return _channel.invokeMethod('identify', {
      'userId': userId,
      'traits': jsonEncode(t),
    });
  }

  Future<void> reset() {
    _forEachProvider((p) => p.setUser(null, const <String, Object?>{}));
    return _channel.invokeMethod('reset');
  }

  // Event rewrite rules (Phase 2 — config-driven). Install from remote config
  // via setEventRules(); a matching rule renames an auto-captured event into a
  // business event + merges props, at this single chokepoint.
  List<UniTrackEventRule> _eventRules = const [];
  void setEventRules(List<UniTrackEventRule> rules) { _eventRules = rules; }

  // Returns the rewritten (name, props) as a MapEntry, or null if no rule
  // matched. (MapEntry instead of a record tuple, to keep this compatible with
  // host apps pinning an older Dart language version.)
  MapEntry<String, Map<String, Object?>>? _applyRules(
      String event, Map<String, Object?> props) {
    final screen = (props['screen'] ?? props['screen_name']) as String?;
    final elem = props['element_key'] as String?;
    for (final r in _eventRules) {
      if (r.matchEvent != event) continue;
      if (r.matchScreen != null && r.matchScreen != screen) continue;
      if (r.matchElementKey != null && r.matchElementKey != elem) continue;
      return MapEntry(r.toName, {...props, ...r.addProps});
    }
    return null;
  }

  Future<void> track(String event, {Map<String, Object?>? properties}) {
    var props = properties ?? const <String, Object?>{};
    var name = event;
    // Phase 2: a config rule may rewrite an auto-captured event before sending.
    final rewritten = _applyRules(event, props);
    if (rewritten != null) { name = rewritten.key; props = rewritten.value; }
    // Forward to every registered provider (Snowplow, Firebase, …).
    _forEachProvider((p) => p.track(name, props));
    return _channel.invokeMethod('track', {
      'event': name,
      'props': jsonEncode(props),
    });
  }

  Future<void> setScreen(String name) {
    _forEachProvider((p) => p.setScreen(name));
    return _channel.invokeMethod('setScreen', {'name': name});
  }

  // --- semantic event helpers (Phase 3) -----------------------------------
  // All funnel through track(), so they inherit device metadata + the offline
  // queue. They give a typed, consistent shape for common app moments.

  /// A push/local notification was received or interacted with.
  /// [state]: 'foreground' | 'background' | 'silent'. [action]: 'received' | 'opened'.
  Future<void> trackNotification({
    required String state,
    String action = 'received',
    String? title,
    String? body,
    Map<String, Object?>? data,
  }) =>
      track('notification', properties: {
        'state': state,
        'action': action,
        if (title != null) 'title': title,
        if (body != null) 'body': body,
        if (data != null) 'data': data,
      });

  /// Drop-in notification auto-capture: forward a notification here from your
  /// FCM / flutter_local_notifications callback and the SDK derives [state]
  /// automatically — no need to compute foreground/background yourself.
  ///
  ///   FirebaseMessaging.onMessage.listen((m) => UniTrack.instance
  ///       .captureNotification(
  ///         hasVisibleContent: m.notification != null,
  ///         action: 'received',
  ///         title: m.notification?.title, body: m.notification?.body,
  ///         data: m.data));
  ///
  /// State rules: no visible content -> 'silent'; app resumed -> 'foreground';
  /// otherwise -> 'background'.
  Future<void> captureNotification({
    required bool hasVisibleContent,
    String action = 'received',
    String? title,
    String? body,
    Map<String, Object?>? data,
  }) {
    final resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final state = !hasVisibleContent
        ? 'silent'
        : (resumed ? 'foreground' : 'background');
    return trackNotification(
      state: state,
      action: action,
      title: title,
      body: body,
      data: data,
    );
  }

  /// A WebView was opened with [url].
  Future<void> trackWebViewOpen(String url, {String? screen}) =>
      track('webview_open', properties: {
        'url': _hostPath(url),
        if (screen != null) 'screen': screen,
      });

  /// A deeplink / universal link opened the app or a screen.
  Future<void> trackDeeplink(String url, {String? source}) =>
      track('deeplink', properties: {
        'url': _hostPath(url),
        if (source != null) 'source': source,
      });

  /// A third-party app / SDK was opened (e.g. payment, social share, maps).
  Future<void> trackThirdPartyOpen(String name, {String? screen}) =>
      track('third_party_open', properties: {
        'target': name,
        if (screen != null) 'screen': screen,
      });

  // Strip query strings for privacy — log host + path only.
  static String _hostPath(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    return u.hasScheme ? '${u.scheme}://${u.host}${u.path}' : u.path;
  }

  Future<void> flush() => _channel.invokeMethod('flush');

  Future<void> setEnabled(bool enabled) =>
      _channel.invokeMethod('setEnabled', {'enabled': enabled});

  /// Install global HTTP auto-capture: every request/error is tracked, with the
  /// button + screen that triggered it (mirrored from [UniTrackTapObserver]).
  /// Call once at startup, after [initialize]. Returns the previous overrides.
  static HttpOverrides? installHttpAutoCapture({
    List<String> excludeSubstrings = const [],
    UniTrackBodyCapture body = const UniTrackBodyCapture(),
  }) =>
      installUniTrackHttpAutoCapture(excludeSubstrings: excludeSubstrings, body: body);
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
