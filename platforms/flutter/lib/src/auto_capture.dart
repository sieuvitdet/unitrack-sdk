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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
// For resolving the widget class behind Material/Cupertino page routes so the
// screen name is the class (ProductListScreen) rather than the path (/products).
import 'package:flutter/material.dart' show MaterialPageRoute, Tooltip;
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;

import '../unitrack.dart';
import 'trace_context.dart';

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

    final flutterScreen = UniTrackTapObserver.routeObserver.currentScreen;
    // When the Flutter route observer doesn't know the screen (the user is on a
    // NATIVE / webview screen — my_pt, mobimap, STWebController…), don't send a
    // bogus 'unknown'. Omit `screen` so the core uses its current_screen_, which
    // the native iOS/Android view-controller swizzler keeps up to date.
    final known = flutterScreen.isNotEmpty && flutterScreen != 'unknown';
    UniTrackTapObserver.lastTap = LastTap(resolved.key, known ? flutterScreen : '', now);

    // Classify the source widget. Flutter AOT strips reflection, so we can't
    // ask the runtime which package a class came from — match by class-name
    // prefix instead. Material / Cupertino widgets are easy (their public
    // names start with well-known tokens); private widgets used by those
    // libraries (e.g. `_InkResponseStateMixin`) start with underscore + a
    // material-flavour name. Everything else → "app".
    final pkg = _classifyFlutterWidget(resolved.type);
    // Debug breadcrumb so app authors can see exactly what the auto-tap
     // captured (element_key, screen, widget type). Without this they have to
     // guess what to put into portal rule fields. Off in release.
    // `class_name` prefers the enclosing app widget (CustomButton) over the
    // raw interactive type (GestureDetector). That makes the field useful as
    // a portal rule match_class_name: it points at an app component the dev
    // already named, instead of the framework primitive every tap collapses to.
    final className = resolved.wrapperClass ?? resolved.type;
    assert(() {
      // ignore: avoid_print
      debugPrint('[unitrack] tap element_key="${resolved.key}" '
          'screen="${known ? flutterScreen : "(none)"}" '
          'class_name=$className (interactive=${resolved.type}) '
          'package=$pkg');
      return true;
    }());
    UniTrack.instance.track('tap', properties: {
      // `element_key` is the canonical cross-platform name (matches iOS/Android
      // bindings + portal rule field `match_element_key`). Keep `element` as
      // a backwards-compat alias for any portal query still on the old key.
      'element_key': resolved.key,
      'element': resolved.key,
      'element_type': resolved.type,            // raw interactive widget type
      'class_name': className,                  // wrapper class if any, else type
      if (resolved.wrapperClass != null) 'wrapper_class': resolved.wrapperClass,
      'framework': 'flutter',
      'package': pkg,
      if (known) 'screen': flutterScreen,
      if (resolved.text != null) 'label': resolved.text,
    });
  }

  /// Coarse classification by widget runtime-type name. We can't read the
  /// originating Dart package on release builds (no mirrors), so this is a
  /// prefix-match allowlist that covers the standard library and falls back
  /// to "app" — same idea as the Android FQCN bucketing.
  String _classifyFlutterWidget(String type) {
    // Drop the leading "_" some private widgets carry.
    final t = type.startsWith('_') ? type.substring(1) : type;
    // Cupertino names are obvious; check before material so Material's
    // catch-all doesn't swallow them.
    const cupertinoPrefixes = ['Cupertino'];
    const materialPrefixes = [
      'Material', 'Scaffold', 'AppBar', 'ElevatedButton', 'TextButton',
      'OutlinedButton', 'FloatingActionButton', 'IconButton', 'InkWell',
      'InkResponse', 'ListTile', 'Card', 'Drawer', 'BottomNavigationBar',
      'TabBar', 'Tab', 'Chip', 'Switch', 'Checkbox', 'Radio', 'Slider',
    ];
    const widgetsPrefixes = [
      'GestureDetector', 'Listener', 'Semantics', 'Text', 'Icon',
      'Container', 'Row', 'Column', 'Stack', 'Padding', 'SizedBox',
    ];
    for (final p in cupertinoPrefixes) { if (t.startsWith(p)) return 'cupertino'; }
    for (final p in materialPrefixes)  { if (t.startsWith(p)) return 'material'; }
    for (final p in widgetsPrefixes)   { if (t.startsWith(p)) return 'widgets'; }
    return 'app';
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

    String? semantic;       // Semantics identifier or label
    String? keyLabel;       // ValueKey
    String? text;           // visible Text
    String? tooltip;        // Tooltip message (common on IconButtons)
    String? iconName;       // IconData semantic label (icon-only buttons)
    String? interactiveType;
    Element? interactiveEl;
    // First app-defined widget class walked outward from the hit point.
    // E.g. tapping inside `CustomButton(child: GestureDetector(child: Text))`,
    // interactiveType resolves to GestureDetector but wrapperClass picks
    // CustomButton — a stable handle for portal rules to target.
    String? wrapperClass;

    for (final el in chain.reversed) {
      final w = el.widget;
      if (wrapperClass == null) {
        final t = w.runtimeType.toString();
        // Skip generated `_*State` and obvious Material/Cupertino/widgets
        // names — those aren't useful app component handles. Public app
        // classes (CustomButton, CheckoutTile) get picked up here.
        if (!t.startsWith('_') && _classifyFlutterWidget(t) == 'app') {
          wrapperClass = t;
        }
      }
      if (semantic == null && w is Semantics) {
        final id = w.properties.identifier;
        final lbl = w.properties.label;
        if (id != null && id.isNotEmpty) semantic = id;
        else if (lbl != null && lbl.isNotEmpty) semantic = lbl;
      }
      if (keyLabel == null && w.key is ValueKey) {
        final v = (w.key as ValueKey).value;
        // Ignore generic container/layout keys that aren't a real element name
        // (apps reuse keys like 'main'/'body' on wrapper widgets, which would
        // otherwise label every tap the same).
        const generic = {'main','root','body','container','content','wrapper','scaffold','page','screen'};
        if (v is String && v.isNotEmpty && !generic.contains(v.toLowerCase())) keyLabel = v;
      }
      if (text == null && w is Text && (w.data?.isNotEmpty ?? false)) {
        text = w.data;
      }
      if (tooltip == null && w is Tooltip && (w.message?.isNotEmpty ?? false)) {
        tooltip = w.message;
      }
      if (iconName == null && w is Icon) {
        iconName = _iconName(w.icon);
      }
      if (interactiveType == null && _isInteractive(w)) {
        interactiveType = w.runtimeType.toString();
        interactiveEl = el;
      }
    }

    if (interactiveType == null && semantic == null && keyLabel == null) {
      return null;
    }

    // If the hit point missed the label/icon (tapping empty area of a Card/
    // InkWell whose content sits in a sibling branch), search the interactive
    // widget's subtree for a Text, then an Icon.
    if (text == null && interactiveEl != null) {
      text = _firstTextIn(interactiveEl);
    }
    if (text == null && iconName == null && interactiveEl != null) {
      iconName = _firstIconIn(interactiveEl);
    }

    // Name priority: explicit semantic/key > visible text > tooltip > icon name
    // (icon-only buttons) > widget type. tooltip/icon mean an icon button gets a
    // real name ("delete", "icon:add") instead of just "IconButton".
    // Priority: explicit Semantics > visible text label > tooltip > non-generic
    // ValueKey > icon name > widget type. Visible text is preferred over a key
    // because the button's text ("Cập nhật") is more meaningful than a reused
    // layout key ("main").
    final key = semantic ?? text ?? tooltip ?? keyLabel
        ?? (iconName != null ? 'icon:$iconName' : null) ?? interactiveType!;

    // Noise filter: a GestureDetector is a WEAK interactive signal — apps wrap
    // whole rows / text blocks / avatars in one. When the only interactive
    // widget is a GestureDetector AND there's no explicit name (Semantics/Key/
    // Tooltip/Icon), the resolved key is just whatever text sat under the
    // finger — a user name, a long content string, a lone emoji. Skip those so
    // the data isn't polluted. Real buttons (InkWell/ElevatedButton/IconButton/
    // ListTile/...) are always kept.
    final weakOnly = interactiveType == 'GestureDetector'
        && semantic == null && keyLabel == null && tooltip == null && iconName == null;
    if (weakOnly) {
      final t = (text ?? '').trim();
      // long content string, empty, or pure emoji/symbol → not a button label
      final wordish = RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(t);
      if (t.isEmpty || t.length > 40 || !wordish) return null;
    }
    return _ResolvedTap(
      key: key,
      type: interactiveType ?? 'unknown',
      wrapperClass: wrapperClass,
      text: text ?? tooltip,
    );
  }

  // Resolve a readable name from an IconData. Flutter's IconData has a
  // semanticLabel only sometimes; otherwise we derive from the const name when
  // available (toString → "IconData(U+0E047)"), so prefer the codepoint hex as
  // a stable id. Material Icons expose their name via the widget's
  // semanticLabel; fall back to the codepoint.
  String? _iconName(IconData? icon) {
    if (icon == null) return null;
    // Material `Icons.x` const instances stringify usefully in debug; in release
    // we only have the codepoint. Use a short hex id so the same icon groups.
    final cp = icon.codePoint.toRadixString(16);
    return 'u$cp';
  }

  String? _firstIconIn(Element root) {
    String? found;
    void walk(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (w is Icon) { found = _iconName(w.icon); if (found != null) return; }
      el.visitChildren(walk);
    }
    root.visitChildren(walk);
    return found;
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
  /// Nearest enclosing app-defined widget class (e.g. `CustomButton`) walked
  /// upward from the interactive widget. `null` if the chain is all
  /// Material/Cupertino/widgets builtins. Lets portal rules target a stable
  /// app component instead of text labels that change per-locale.
  final String? wrapperClass;
  final String? text;
  _ResolvedTap({required this.key, required this.type, this.wrapperClass, this.text});
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

    // Measure load_ms = didPush → first endOfFrame. Mirrors the iOS swizzler's
    // viewDidLoad → viewDidAppear and the Android FragmentLifecycleCallbacks'
    // onFragmentCreated → onFragmentResumed window. Skipped for didPop since
    // popping returns to an already-laid-out screen (load_ms would be ~0 and
    // misleading; we just re-setScreen for the destination above).
    if (!_measureLoad) return;
    _measureLoad = false;
    final startedAt = DateTime.now();
    WidgetsBinding.instance.endOfFrame.then((_) {
      final loadMs = DateTime.now().difference(startedAt).inMilliseconds;
      UniTrack.instance.track(UniTrack.screenLoadEventName, properties: {
        'screen': name,
        'load_ms': loadMs,
      });
    });
  }

  // Single-shot guard: didPush and didReplace measure; didPop does not.
  bool _measureLoad = false;

  /// Resolve the most meaningful name for a route:
  ///   0. auto_route AutoRoutePage → settings.routeData.name (duck-typed
  ///      because auto_route is an optional dep — we can't import it here);
  ///   1. the class of the widget it builds (ProductListScreen), if obtainable;
  ///   2. else the route's settings.name (/products);
  ///   3. else the route's own runtimeType.
  String _screenName(PageRoute<dynamic> r) {
    final autoRouteName = _autoRouteName(r);
    if (autoRouteName != null && autoRouteName.isNotEmpty) return autoRouteName;
    final widgetType = _builtWidgetType(r);
    if (widgetType != null && widgetType.isNotEmpty) return widgetType;
    // settings.name is often '/' or empty for unnamed routes — those aren't
    // useful screen names, so fall back to the route's runtimeType instead.
    final n = r.settings.name;
    if (n != null && n.isNotEmpty && n != '/') return n;
    return r.runtimeType.toString();
  }

  /// auto_route puts every route's logical name on `AutoRoutePage.routeData.name`
  /// (e.g. `DetailDeploymentRemainingShiftRoute`). The page object is `r.settings`
  /// (auto_route uses the Flutter Pages API), so we can read it through dynamic
  /// duck-typing — keeps auto_route an OPTIONAL dependency that the SDK never
  /// imports. Apps not using auto_route just see this return null and the next
  /// resolution step picks up.
  String? _autoRouteName(PageRoute<dynamic> r) {
    try {
      final s = r.settings;
      // settings is the Page object on auto_route routes; its runtime type
      // typically starts with "AutoRoutePage" (with a generic suffix).
      if (!s.runtimeType.toString().contains('AutoRoutePage')) return null;
      final routeData = (s as dynamic).routeData;
      if (routeData == null) return null;
      final name = routeData.name;
      if (name is String && name.isNotEmpty) return name;
    } catch (_) {
      // settings isn't an AutoRoutePage, or auto_route shape changed — fine,
      // the caller will fall through to widget-type / settings.name.
    }
    return null;
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
  void didPush(Route route, Route? previousRoute) {
    _measureLoad = true;
    _set(route);
  }
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    _measureLoad = true;
    _set(newRoute);
  }
  @override
  void didPop(Route route, Route? previousRoute) {
    // didPop: returning to a previously-built route — no load measurement.
    _set(previousRoute);
  }
}

// ---------------------------------------------------------------------------
// HTTP auto-capture
// ---------------------------------------------------------------------------

/// Installs a global HttpOverrides that records every HTTP request/error and
/// mirrors the last tap (button + screen) that triggered it. Call once at
/// startup. Returns the previous overrides so callers can chain if needed.
/// Options for HTTP body capture. OFF by default for privacy — request and
/// response bodies often contain credentials / PII. Opt in explicitly.
class UniTrackBodyCapture {
  /// Capture the request body the app writes (add/write/addStream).
  final bool request;
  /// Capture the response body the app reads.
  final bool response;
  /// Truncate captured bodies to this many characters (avoid huge payloads).
  final int maxChars;
  const UniTrackBodyCapture({
    this.request = false,
    this.response = false,
    this.maxChars = 4096,
  });
  bool get any => request || response;
}

/// [excludeSubstrings]: request URLs containing any of these are NOT tracked —
/// pass the analytics ingest endpoint(s) here so the SDK never tracks its own
/// uploads (which otherwise floods the data with thousands of self-calls).
/// [body]: opt-in request/response body capture (off by default).
HttpOverrides? installUniTrackHttpAutoCapture({
  List<String> excludeSubstrings = const [],
  UniTrackBodyCapture body = const UniTrackBodyCapture(),
}) {
  final previous = HttpOverrides.current;
  HttpOverrides.global = _UniTrackHttpOverrides(previous, excludeSubstrings, body);
  return previous;
}

class _UniTrackHttpOverrides extends HttpOverrides {
  final HttpOverrides? _previous;
  final List<String> _exclude;
  final UniTrackBodyCapture _body;
  _UniTrackHttpOverrides(this._previous, this._exclude, this._body);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = _previous?.createHttpClient(context) ??
        super.createHttpClient(context);
    return _TrackingHttpClient(inner, _exclude, _body);
  }
}

class _TrackingHttpClient implements HttpClient {
  final HttpClient _inner;
  final List<String> _exclude;
  final UniTrackBodyCapture _body;
  _TrackingHttpClient(this._inner,
      [this._exclude = const [], this._body = const UniTrackBodyCapture()]);

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

    // W3C tracing: mint (trace_id, span_id), inject the header if the host is
    // on the allowlist, and remember the ids so the network_request event
    // logged on close() carries them too. Don't clobber an existing header —
    // an upstream tool may already be propagating its own trace.
    UniTrackTraceIds? ids;
    final tc = unitrackTracing;
    if (tc.enabled
        && UniTrackTraceContext.shouldInject(url.host, tc.allowlistHosts)
        && request.headers.value(tc.headerName) == null) {
      ids = UniTrackTraceContext.newTrace();
      request.headers.set(
        tc.headerName,
        UniTrackTraceContext.traceparent(ids, sampled: tc.sampled),
      );
    }

    return _TrackingHttpRequest(request, method, url, started, _body, ids);
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
  final UniTrackBodyCapture _body;
  // Trace ids minted in openUrl() so the same pair appears on the wire header
  // AND in the network_request event we log on completion. null when tracing
  // is disabled / host not on the allowlist / upstream set their own header.
  final UniTrackTraceIds? _traceIds;
  // Accumulates the request body bytes the app writes (only when opted in).
  final List<int> _reqBytes = [];
  _TrackingHttpRequest(this._inner, this._method, this._url, this._started,
      this._body, [this._traceIds]);

  // Decode + truncate captured bytes to a readable string.
  String? _decode(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      var s = utf8.decode(bytes, allowMalformed: true);
      if (s.length > _body.maxChars) s = s.substring(0, _body.maxChars) + '…';
      return s;
    } catch (_) { return '<${bytes.length} bytes>'; }
  }

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await _inner.close();
      if (_body.response) {
        // Tee the response stream: hand the app a fresh stream while we collect
        // a (truncated) copy. We don't block the app — report once drained.
        final collected = <int>[];
        final controller = StreamController<List<int>>();
        response.listen((chunk) {
          if (collected.length < _body.maxChars * 2) collected.addAll(chunk);
          controller.add(chunk);
        }, onError: (e, st) {
          _report(status: response.statusCode, respBody: _decode(collected));
          controller.addError(e, st);
        }, onDone: () {
          _report(status: response.statusCode, respBody: _decode(collected));
          controller.close();
        }, cancelOnError: false);
        return _ReplayHttpResponse(response, controller.stream);
      }
      _report(status: response.statusCode);
      return response;
    } catch (e) {
      _report(status: 0, error: e.toString());
      rethrow;
    }
  }

  void _report({required int status, String? error, String? respBody}) {
    final durationMs = DateTime.now().difference(_started).inMilliseconds;
    final tap = UniTrackTapObserver.lastTap;
    final mirrored = tap != null && tap.isFresh;
    final ok = status >= 200 && status < 400 && error == null;
    final reqBody = _body.request ? _decode(_reqBytes) : null;

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
      if (reqBody != null) 'request_body': reqBody,
      if (respBody != null) 'response_body': respBody,
      // Carry the trace ids on the event so the portal can offer a "copy
      // trace_id → grep backend logs" affordance per request.
      if (_traceIds != null) 'trace_id': _traceIds!.traceId,
      if (_traceIds != null) 'span_id':  _traceIds!.spanId,
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
  // Capture request-body bytes (capped) as the app writes them, when opted in.
  void _capReq(List<int> data) {
    if (!_body.request) return;
    if (_reqBytes.length < _body.maxChars * 2) _reqBytes.addAll(data);
  }

  @override
  void add(List<int> data) { _capReq(data); _inner.add(data); }
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) {
    if (!_body.request) return _inner.addStream(stream);
    // Tee: capture a copy while forwarding to the real request.
    return _inner.addStream(stream.map((chunk) { _capReq(chunk); return chunk; }));
  }
  @override
  Future flush() => _inner.flush();
  @override
  void write(Object? object) { _capReq(utf8.encode(object?.toString() ?? '')); _inner.write(object); }
  @override
  void writeAll(Iterable objects, [String separator = '']) {
    _capReq(utf8.encode(objects.join(separator)));
    _inner.writeAll(objects, separator);
  }
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) { _capReq(utf8.encode('${object ?? ''}\n')); _inner.writeln(object); }
}

/// Wraps an HttpClientResponse, replacing its data stream with a teed copy so
/// the SDK can read the body without consuming it from the app. All other
/// response API is forwarded to the original.
class _ReplayHttpResponse extends StreamView<List<int>> implements HttpClientResponse {
  final HttpClientResponse _inner;
  _ReplayHttpResponse(this._inner, Stream<List<int>> stream) : super(stream);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override int get statusCode => _inner.statusCode;
  @override String get reasonPhrase => _inner.reasonPhrase;
  @override HttpHeaders get headers => _inner.headers;
  @override int get contentLength => _inner.contentLength;
  @override List<Cookie> get cookies => _inner.cookies;
  @override bool get isRedirect => _inner.isRedirect;
  @override bool get persistentConnection => _inner.persistentConnection;
  @override HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override X509Certificate? get certificate => _inner.certificate;
  @override HttpClientResponseCompressionState get compressionState => _inner.compressionState;
  @override List<RedirectInfo> get redirects => _inner.redirects;
  @override Future<HttpClientResponse> redirect([String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);
  @override Future<Socket> detachSocket() => _inner.detachSocket();
}
