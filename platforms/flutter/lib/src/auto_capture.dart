// UniTrack Flutter — Dart-layer auto-capture.
//
// Flutter renders its whole UI into a single native view, so the native SDK's
// tap/network swizzlers cannot see which Flutter widget was tapped or which
// call an HTTP request belongs to. This file fills that gap at the Dart layer,
// while still pushing every event through the SDK (UniTrack.instance) so the
// native core handles batching, the offline queue, sessions and transport.
//
// Two pieces, both declared ONCE at app startup:
//
//   void main() {
//     WidgetsFlutterBinding.ensureInitialized();
//     await UniTrack.instance.initialize('KEY', config: ...);
//     UniTrack.installHttpAutoCapture();                 // network + mirror tap
//     runApp(UniTrackTapObserver(child: MyApp(           // taps + screen names
//       navigatorObservers: [UniTrackTapObserver.routeObserver],
//     )));
//   }
//
// After that, every tap (with the button name + screen) and every HTTP
// request/error (with the button + screen that triggered it) is tracked with
// no per-widget or per-call code.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
// For resolving the widget class behind Material/Cupertino page routes so the
// screen name is the class (ProductListScreen) rather than the path (/products).
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;

import '../unitrack.dart';

// ---------------------------------------------------------------------------
// Tap + screen auto-capture
// ---------------------------------------------------------------------------

/// Wrap your app once with this widget to auto-capture every tap.
class UniTrackTapObserver extends StatefulWidget {
  final Widget child;

  /// Minimum gap between identical taps, to suppress double-fire.
  final Duration debounce;

  const UniTrackTapObserver({
    super.key,
    required this.child,
    this.debounce = const Duration(milliseconds: 250),
  });

  /// Add to MaterialApp.navigatorObservers so taps/network know the current
  /// screen, and to forward screen_view automatically.
  static final UniTrackRouteObserver routeObserver = UniTrackRouteObserver();

  /// The most recent tap — read by HTTP auto-capture to attribute a request to
  /// the button + screen that triggered it.
  static LastTap? lastTap;

  @override
  State<UniTrackTapObserver> createState() => _UniTrackTapObserverState();
}

/// Snapshot of the last user tap, used to mirror taps onto network events.
class LastTap {
  final String element;
  final String screen;
  final DateTime at;
  LastTap(this.element, this.screen, this.at);

  bool get isFresh => DateTime.now().difference(at) < const Duration(seconds: 10);
}

class _UniTrackTapObserverState extends State<UniTrackTapObserver> {
  String _lastKey = '';
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: _onPointerUp,
      child: widget.child,
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    final resolved = _resolveAt(event.position);
    if (resolved == null) return;

    final now = DateTime.now();
    if (resolved.key == _lastKey &&
        now.difference(_lastAt) < widget.debounce) {
      return;
    }
    _lastKey = resolved.key;
    _lastAt = now;

    final screen = UniTrackTapObserver.routeObserver.currentScreen;
    UniTrackTapObserver.lastTap = LastTap(resolved.key, screen, now);

    UniTrack.instance.track('tap', properties: {
      'element': resolved.key,
      'element_type': resolved.type,
      'screen': screen,
      if (resolved.text != null) 'label': resolved.text,
    });
  }

  /// Find the deepest interactive widget under [point] by walking the element
  /// tree (release-safe), then resolve the most meaningful name. Priority:
  ///   1. Semantics(identifier:)
  ///   2. ValueKey
  ///   3. Text label inside the widget (incl. its subtree)
  ///   4. Interactive widget type
  _ResolvedTap? _resolveAt(Offset point) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;

    final chain = <Element>[];
    void visit(Element el) {
      final ro = el.renderObject;
      if (ro is RenderBox && ro.hasSize && ro.attached) {
        final topLeft = ro.localToGlobal(Offset.zero);
        final rect = topLeft & ro.size;
        if (!rect.contains(point)) return;
        chain.add(el);
      }
      el.visitChildren(visit);
    }

    visit(root);
    if (chain.isEmpty) return null;

    String? semantic;
    String? keyLabel;
    String? text;
    String? interactiveType;
    Element? interactiveEl;

    for (final el in chain.reversed) {
      final w = el.widget;
      if (semantic == null && w is Semantics) {
        final id = w.properties.identifier;
        if (id != null && id.isNotEmpty) semantic = id;
      }
      if (keyLabel == null && w.key is ValueKey) {
        final v = (w.key as ValueKey).value;
        if (v is String && v.isNotEmpty) keyLabel = v;
      }
      if (text == null && w is Text && (w.data?.isNotEmpty ?? false)) {
        text = w.data;
      }
      if (interactiveType == null && _isInteractive(w)) {
        interactiveType = w.runtimeType.toString();
        interactiveEl = el;
      }
    }

    if (interactiveType == null && semantic == null && keyLabel == null) {
      return null;
    }

    // If the hit point missed the label (tapping the empty area of a
    // Card/InkWell whose Text sits in a sibling branch), search the interactive
    // widget's subtree for its label.
    if (text == null && interactiveEl != null) {
      text = _firstTextIn(interactiveEl);
    }

    final key = semantic ?? keyLabel ?? text ?? interactiveType!;
    return _ResolvedTap(key: key, type: interactiveType ?? 'unknown', text: text);
  }

  String? _firstTextIn(Element root) {
    String? found;
    void walk(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (w is Text && (w.data?.isNotEmpty ?? false)) {
        found = w.data;
        return;
      }
      el.visitChildren(walk);
    }
    root.visitChildren(walk);
    return found;
  }

  bool _isInteractive(Widget w) {
    final t = w.runtimeType.toString();
    // Match by type name to avoid importing material — keeps this widgets-only.
    const interactive = {
      'InkWell', 'InkResponse', 'GestureDetector',
      'ElevatedButton', 'TextButton', 'FilledButton', 'OutlinedButton',
      'IconButton', 'ListTile', 'ChoiceChip', 'ActionChip', 'InputChip',
      'FloatingActionButton', 'SwitchListTile', 'RadioListTile', 'CheckboxListTile',
      'CupertinoButton', 'Radio', 'Switch', 'Checkbox',
    };
    if (interactive.contains(t)) return true;
    // ButtonStyleButton subclasses (e.g. _FilledButtonWithIcon) end with these.
    return t.contains('Button');
  }
}

class _ResolvedTap {
  final String key;
  final String type;
  final String? text;
  _ResolvedTap({required this.key, required this.type, this.text});
}

/// Tracks the current screen and forwards screen_view to the SDK.
///
/// The screen name is the WIDGET CLASS the route builds (e.g.
/// `ProductListScreen`) rather than the route path (`/products`), since the
/// class name is more meaningful for analytics. Falls back to the route name,
/// then the route's runtimeType, if the widget class can't be resolved.
class UniTrackRouteObserver extends NavigatorObserver {
  String currentScreen = 'unknown';

  void _set(Route<dynamic>? r) {
    if (r is! PageRoute) return;
    final name = _screenName(r);
    currentScreen = name;
    UniTrack.instance.setScreen(name);
  }

  /// Resolve the most meaningful name for a route:
  ///   1. the class of the widget it builds (ProductListScreen), if obtainable;
  ///   2. else the route's settings.name (/products);
  ///   3. else the route's own runtimeType.
  String _screenName(PageRoute<dynamic> r) {
    final widgetType = _builtWidgetType(r);
    if (widgetType != null) return widgetType;
    return r.settings.name ?? r.runtimeType.toString();
  }

  /// Build the route's widget once (in the navigator's context) and read its
  /// runtimeType. Wrapped in try/catch — a builder that needs a real element
  /// tree must never break navigation/tracking; we just fall back then.
  String? _builtWidgetType(PageRoute<dynamic> r) {
    final ctx = navigator?.context;
    if (ctx == null) return null;
    try {
      if (r is MaterialPageRoute) {
        return r.builder(ctx).runtimeType.toString();
      }
      if (r is CupertinoPageRoute) {
        return r.builder(ctx).runtimeType.toString();
      }
    } catch (_) {
      // builder threw (e.g. needs InheritedWidgets not present here) — ignore.
    }
    return null;
  }

  @override
  void didPush(Route route, Route? previousRoute) => _set(route);
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _set(newRoute);
  @override
  void didPop(Route route, Route? previousRoute) => _set(previousRoute);
}

// ---------------------------------------------------------------------------
// HTTP auto-capture
// ---------------------------------------------------------------------------

/// Installs a global HttpOverrides that records every HTTP request/error and
/// mirrors the last tap (button + screen) that triggered it. Call once at
/// startup. Returns the previous overrides so callers can chain if needed.
/// [excludeSubstrings]: request URLs containing any of these are NOT tracked —
/// pass the analytics ingest endpoint(s) here so the SDK never tracks its own
/// uploads (which otherwise floods the data with thousands of self-calls).
HttpOverrides? installUniTrackHttpAutoCapture({List<String> excludeSubstrings = const []}) {
  final previous = HttpOverrides.current;
  HttpOverrides.global = _UniTrackHttpOverrides(previous, excludeSubstrings);
  return previous;
}

class _UniTrackHttpOverrides extends HttpOverrides {
  final HttpOverrides? _previous;
  final List<String> _exclude;
  _UniTrackHttpOverrides(this._previous, this._exclude);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = _previous?.createHttpClient(context) ??
        super.createHttpClient(context);
    return _TrackingHttpClient(inner, _exclude);
  }
}

class _TrackingHttpClient implements HttpClient {
  final HttpClient _inner;
  final List<String> _exclude;
  _TrackingHttpClient(this._inner, [this._exclude = const []]);

  bool _isExcluded(Uri url) {
    final s = url.toString();
    for (final e in _exclude) { if (e.isNotEmpty && s.contains(e)) return true; }
    return false;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    // Never track the SDK's own analytics uploads → avoids a feedback loop.
    if (_isExcluded(url)) return _inner.openUrl(method, url);
    final started = DateTime.now();
    final request = await _inner.openUrl(method, url);
    return _TrackingHttpRequest(request, method, url, started);
  }

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials c) =>
      _inner.addCredentials(url, realm, c);
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials c) =>
      _inner.addProxyCredentials(host, port, realm, c);
  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(Future<bool> Function(String, int, String, String?)? f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(bool Function(X509Certificate, String, int)? cb) =>
      _inner.badCertificateCallback = cb;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? f) =>
      _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri)? f) => _inner.findProxy = f;
  @override
  set keyLog(Function(String)? f) => _inner.keyLog = f;
  @override
  void close({bool force = false}) => _inner.close(force: force);
}

class _TrackingHttpRequest implements HttpClientRequest {
  final HttpClientRequest _inner;
  final String _method;
  final Uri _url;
  final DateTime _started;
  _TrackingHttpRequest(this._inner, this._method, this._url, this._started);

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await _inner.close();
      _report(status: response.statusCode);
      return response;
    } catch (e) {
      _report(status: 0, error: e.toString());
      rethrow;
    }
  }

  void _report({required int status, String? error}) {
    final durationMs = DateTime.now().difference(_started).inMilliseconds;
    final tap = UniTrackTapObserver.lastTap;
    final mirrored = tap != null && tap.isFresh;
    final ok = status >= 200 && status < 400 && error == null;

    UniTrack.instance.track(ok ? 'network_request' : 'network_error', properties: {
      'method': _method,
      // Full URL (scheme://host/path?query) so the portal shows the real call.
      'url': _url.toString(),
      'host': _url.host,
      'path': _url.path,
      if (_url.query.isNotEmpty) 'query': _url.query,
      'status': status,
      'duration_ms': durationMs,
      if (error != null) 'error': error,
      if (mirrored) 'triggered_by_element': tap.element,
      if (mirrored) 'triggered_by_screen': tap.screen,
    });
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding v) => _inner.encoding = v;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  Future<HttpClientResponse> get done => _inner.done;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int v) => _inner.contentLength = v;
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool v) => _inner.bufferOutput = v;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool v) => _inner.followRedirects = v;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int v) => _inner.maxRedirects = v;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool v) => _inner.persistentConnection = v;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}
