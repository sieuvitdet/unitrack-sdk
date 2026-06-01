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
  static int maxNodes = 500;

  /// Walk the current screen and emit a `screen_layout` event. Safe to call
  /// from any callback — schedules a post-frame walk so the layout is final.
  static void snapshotCurrentScreen() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  static void _emit() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    final counter = _Counter();
    final tree = _walk(root, counter);
    if (tree == null) return;
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
    counter.value++;

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
    final node = <String, Object?>{
      'id':   counter.value,
      'type': widget.runtimeType.toString(),
      'x':    x, 'y': y, 'w': w, 'h': h,
    };
    // Cheap label hints — same shape as iOS/Android.
    if (widget is Text) {
      final t = widget.data;
      if (t != null && t.isNotEmpty) node['text'] = _trim(t);
    }
    if (widget is Semantics) {
      final lbl = widget.properties.label;
      if (lbl != null && lbl.isNotEmpty) node['aid'] = lbl;
    }

    final children = <Map<String, Object?>>[];
    el.visitChildren((c) {
      if (counter.value >= maxNodes) return;
      final node = _walk(c, counter);
      if (node != null) children.add(node);
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
