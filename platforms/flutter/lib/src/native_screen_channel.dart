// UniTrack Flutter — cross-language layer registry bridge.
//
// Mirrors the C-core layer enum (see core/include/unitrack/unitrack.h
// §"Layer registry"). When a Flutter app is hosted inside a native iOS
// process that also runs the native UniTrack SDK, both layers' screen
// observers fire on every route change. The bitmask + claim_subtree
// arbitration lives in the C core; this file is a thin pass-through.
//
// Also handles the REVERSE direction: when the native swizzler emits a
// screen for a non-Flutter VC (vd Flutter app pushed a UIKit screen via
// plugin), the native plugin invokes `onNativeScreen` on the MethodChannel
// so the Dart route observer's `currentScreen` mirror stays accurate for
// tap attribution. UniTrack._installNativeCallbackHandler dispatches that
// call into [NativeScreenChannel.handleInbound].

import 'auto_capture.dart' show UniTrackTapObserver;

/// Bitmask of the layers a UniTrack process may host. Values match the
/// C enum `ut_layer` exactly so int-encoded MethodChannel hops are lossless.
enum UniTrackLayer {
  iosNative(0x01),
  androidNative(0x02),
  flutter(0x04),
  reactNative(0x08);

  final int raw;
  const UniTrackLayer(this.raw);

  static UniTrackLayer? fromRaw(int? v) {
    if (v == null) return null;
    for (final l in UniTrackLayer.values) { if (l.raw == v) return l; }
    return null;
  }
}

/// Handles the native→Dart side of the cross-language bridge. The
/// outbound (Dart→native) calls are made directly from [UniTrack] methods
/// using the existing MethodChannel.
class NativeScreenChannel {
  /// Update [UniTrackRouteObserver.currentScreen] from a native broadcast.
  /// Called by [UniTrack._installNativeCallbackHandler] when the plugin
  /// invokes `onNativeScreen`. Self-broadcasts are filtered on the native
  /// side, so anything arriving here is genuinely a native screen the
  /// Flutter app reached via plugin / add-to-app embedding.
  static void handleInbound(String screen, int? layerRaw) {
    if (screen.isEmpty) return;
    // Don't emit anything from Dart — native already enqueued screen_view
    // through its own swizzler. We only mirror state so taps fired inside
    // the native screen still get attributed to the right screen name.
    UniTrackTapObserver.routeObserver.currentScreen = screen;
  }
}
