// UniTrack screen wireframe snapshot for Flutter.
//
// Walks the Element tree under the current navigator, captures each
// RenderBox's global frame + widget type + a few label hints, gzips the
// JSON, and emits a `screen_layout` event. The portal stores it for the
// Layout tab.
//
// Trigger: from the app's RouteObserver (or a one-shot call after a
// significant screen change):
//
//   void didPush(Route route, Route? prev) {
//     super.didPush(route, prev);
//     WidgetsBinding.instance.addPostFrameCallback((_) =>
//       UniTrackWireframe.snapshotCurrentScreen());
//   }
//
// We don't auto-install from RouteObserver here because the consuming app
// already owns navigation observers; one extra observer would re-walk on
// every route push including the ones it doesn't want tracked.

import 'dart:convert';
import 'dart:io' show gzip;
import 'package:flutter/widgets.dart';
// widgets.dart re-exports the rendering layer (RenderBox, RenderObject) and
// pulls in foundation transitively, so we don't need the explicit imports.

import '../unitrack.dart';

class UniTrackWireframe {
  /// Beyond this many widgets, the walk stops and `truncated: true` is set.
  /// Most screens are well under — this caps payload for outlier layouts.
  /// Bumped to 3000 from 500 so MobiX's deeply-nested Flutter pages (often
  /// 1000+ Element nodes once material wrappers + provider scopes count)
  /// don't lose the bottom half of the tree.
  static int maxNodes = 3000;

  /// Skip pure-layout container types when serialising. The widget tree
  /// has tons of these (Padding, SizedBox, Builder, Theme, …) that don't
  /// add information to the wireframe — only their CHILDREN matter. Drop
  /// them from the payload and let their children's frames speak for the
  /// layout. Cuts node count 60–70% on typical Material screens.
  static bool skipContainerNodes = true;

  // Widget types we consider pure layout glue. Matches the portal's
  // isContainer() — kept in sync so what we drop here is what the portal
  // would have dashed-outlined anyway. Falls back to "render it" for any
  // type we don't recognise (better to over-include than miss a real widget).
  static final RegExp _containerRe = RegExp(
    r'^_?(Padding|SizedBox|Column|Row|Stack|Container|Flex|Expanded|Align|Center|Positioned|Wrap|Flexible|Material|MaterialApp|Scaffold|SafeArea|Directionality|MediaQuery|LayoutBuilder|Theme|Builder|RepaintBoundary|ClipR|Transform|Offstage|Visibility|FractionallySizedBox|ConstrainedBox|DecoratedBox|Provider|Consumer|Selector|Listener|GestureDetector|Semantics|NotificationListener|FocusScope|Focus|Localizations|IconTheme|IconButtonTheme|DefaultTextStyle|InheritedTheme|HeroController|Navigator|Overlay|MediaQueryFromWindow|RootRestorationScope|UnitToBuildLayer|RawGestureDetector|MouseRegion|AbsorbPointer|IgnorePointer|InteractiveViewer|SliverPadding|SliverList|SliverFillRemaining|CustomMultiChildLayout|SliverToBoxAdapter|CustomScrollView)([A-Z_<].*)?$',
  );

  /// Walk the current screen and emit a `screen_layout` event. Safe to call
  /// from any callback — schedules a post-frame walk so the layout is final.
  static void snapshotCurrentScreen() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  static void _emit() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    final counter = _Counter();
    var tree = _walk(root, counter);
    if (tree == null) return;
    // The root itself might be a layout-only container (MaterialApp / Theme /
    // WidgetsApp wraps the real screen). Unwrap any number of _inline layers
    // until we hit a real widget — or, if every layer is layout-only, fall
    // back to synthesising a viewport-sized root so the portal can compute
    // the bounding box without panicking on a sentinel node.
    while (tree != null && tree['_inline'] == true) {
      final kids = tree['children'] as List<Map<String, Object?>>?;
      if (kids == null || kids.isEmpty) return;
      if (kids.length == 1) {
        tree = kids.first;
      } else {
        // Multiple layout-only roots — wrap them in a synthetic Root node so
        // the portal sees a single top-level tree with a viewport frame.
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final size = view.physicalSize / view.devicePixelRatio;
        tree = {
          'id':   0,
          'type': 'Root',
          'x':    0, 'y': 0,
          'w':    size.width.toInt(),
          'h':    size.height.toInt(),
          'children': kids,
        };
        break;
      }
    }
    final truncated = counter.value >= maxNodes;
    try {
      final json = utf8.encode(jsonEncode(tree));
      final gz = gzip.encode(json);
      final b64 = base64Encode(gz);
      UniTrack.instance.track('screen_layout', properties: {
        'tree_b64gz': b64,
        'node_count': counter.value,
        'truncated':  truncated,
        'framework':  'flutter',
      });
    } catch (_) {
      // Encoding failure — drop the snapshot. Better than crashing the app.
    }
  }

  static Map<String, Object?>? _walk(Element el, _Counter counter) {
    if (counter.value >= maxNodes) return null;

    // Frame from RenderBox if it's laid out. Many widgets have no RenderBox
    // (RenderSliver, RenderProxyBox), so we use 0/0 fallback — render-tree
    // proxies still contribute their CHILDREN to the wireframe.
    int x = 0, y = 0, w = 0, h = 0;
    final ro = el.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      final size = ro.size;
      final origin = ro.localToGlobal(Offset.zero);
      x = origin.dx.toInt();
      y = origin.dy.toInt();
      w = size.width.toInt();
      h = size.height.toInt();
    }
    final widget = el.widget;
    final typeName = widget.runtimeType.toString();

    // Drop pure layout glue (skipContainerNodes default true). The Element
    // tree has tons of Padding/SizedBox/Builder/Theme nodes whose only job
    // is to wrap another widget — they add no info to the wireframe but
    // chew up the maxNodes budget so the meaningful leaves get truncated.
    // Skipping them frees ~60-70% of the cap for real widgets without
    // changing visual output (the children's absolute frames already carry
    // the layout offsets the container applied).
    final isText = widget is Text;
    final isSemantics = widget is Semantics;
    final hasLabel = isText || isSemantics;
    final isLayoutOnly = skipContainerNodes
        && _containerRe.hasMatch(typeName)
        && !hasLabel;

    if (isLayoutOnly) {
      // Don't emit OR count this node — just recurse so its children get
      // their chance to be emitted at the call site. Returning a sentinel
      // with _inline:true lets the caller splice the children into its own
      // list without creating a stale parent node in the payload.
      final passthrough = <Map<String, Object?>>[];
      el.visitChildren((c) {
        if (counter.value >= maxNodes) return;
        final node = _walk(c, counter);
        if (node == null) return;
        if (node['_inline'] == true) {
          final kids = node['children'] as List<Map<String, Object?>>?;
          if (kids != null) passthrough.addAll(kids);
        } else {
          passthrough.add(node);
        }
      });
      if (passthrough.isEmpty) return null;
      return { '_inline': true, 'children': passthrough };
    }

    counter.value++;
    final node = <String, Object?>{
      'id':   counter.value,
      'type': typeName,
      'x':    x, 'y': y, 'w': w, 'h': h,
    };
    if (isText) {
      final t = (widget).data;
      if (t != null && t.isNotEmpty) node['text'] = _trim(t);
    }
    if (isSemantics) {
      final lbl = (widget).properties.label;
      if (lbl != null && lbl.isNotEmpty) node['aid'] = lbl;
    }

    final children = <Map<String, Object?>>[];
    el.visitChildren((c) {
      if (counter.value >= maxNodes) return;
      final cnode = _walk(c, counter);
      if (cnode == null) return;
      if (cnode['_inline'] == true) {
        final kids = cnode['children'] as List<Map<String, Object?>>?;
        if (kids != null) children.addAll(kids);
      } else {
        children.add(cnode);
      }
    });
    if (children.isNotEmpty) node['children'] = children;
    return node;
  }

  static String _trim(String s) => s.length > 64 ? '${s.substring(0, 63)}…' : s;
}

/// Tiny mutable int holder — Dart ints are value types and a `pass by ref`
/// trick (List<int> of size 1) reads worse than this. Used to count nodes
/// across the recursive walk.
class _Counter { int value = 0; }
