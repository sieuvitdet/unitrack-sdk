// LayerRegistry.swift
//
// Swift wrapper for the cross-language layer registry exposed by the C core
// (see core/include/unitrack/unitrack.h §"Layer registry"). When a single
// iOS process hosts more than one UniTrack binding (vd app native nhúng
// Flutter module), each side registers its layer here so the ViewController
// swizzler can detect a boundary VC (FlutterViewController / RCTRootView)
// and yield — the cross-platform layer is responsible for the screen_view
// inside its own subtree, native swizzler keeps owning everything else.
//
// All entrypoints are no-ops until UniTrack.initialize has succeeded.

import Foundation
#if canImport(UniTrackCore)
import UniTrackCore
#endif

enum UniTrackLayer: UInt32 {
    case iOSNative      = 0x01   // UT_LAYER_NATIVE_IOS
    case androidNative  = 0x02   // UT_LAYER_NATIVE_ANDROID (not used on iOS)
    case flutter        = 0x04   // UT_LAYER_FLUTTER
    case reactNative    = 0x08   // UT_LAYER_REACT_NATIVE

    fileprivate var cValue: ut_layer { ut_layer(rawValue: rawValue) }
}

enum LayerRegistry {
    /// Register this binding's layer once. Idempotent on the C side.
    static func register(_ layer: UniTrackLayer) {
        guard let ctx = UniTrack.coreContext else { return }
        ut_register_layer(ctx, layer.cValue)
    }

    /// Bitmask of layers active in this process. Returns 0 before init.
    static var activeLayers: UInt32 {
        guard let ctx = UniTrack.coreContext else { return 0 }
        return ut_active_layers(ctx)
    }

    static func isActive(_ layer: UniTrackLayer) -> Bool {
        (activeLayers & layer.rawValue) != 0
    }

    /// Mark a subtree (typically the host VC) as owned by a cross-platform
    /// layer. The native swizzler reads `owner(of:)` and yields when set.
    static func claim(subtree id: String, by layer: UniTrackLayer) {
        guard let ctx = UniTrack.coreContext else { return }
        ut_claim_subtree(ctx, layer.cValue, id)
    }

    static func release(subtree id: String) {
        guard let ctx = UniTrack.coreContext else { return }
        ut_release_subtree(ctx, id)
    }

    static func owner(of subtree: String) -> UniTrackLayer? {
        guard let ctx = UniTrack.coreContext else { return nil }
        let raw = UInt32(ut_subtree_claimed_by(ctx, subtree).rawValue)
        return UniTrackLayer(rawValue: raw)
    }

    /// Backstop cross-layer dedup window inside core's set_screen. Default
    /// 250 ms; set 0 to disable. See ut_set_screen_dedup_window_ms.
    static func setScreenDedupWindow(ms: Int32) {
        guard let ctx = UniTrack.coreContext else { return }
        ut_set_screen_dedup_window_ms(ctx, ms)
    }

    /// Layer-tagged set_screen so core's dedup can identify the caller.
    /// Native swizzler uses this instead of `ut_set_screen` whenever it
    /// emits a screen so a sibling Flutter SDK that fires the same name
    /// 50 ms later is silently dropped.
    static func setScreen(_ name: String, layer: UniTrackLayer) {
        guard let ctx = UniTrack.coreContext else { return }
        ut_set_screen_for_layer(ctx, name, layer.cValue)
    }
}

/// Stable, short id for a UIViewController instance — used as the subtree
/// id when a Flutter/RN container claims its own view. Pointer-derived so
/// it survives object lifetime; uniqueness within the process is enough.
func unitrackSubtreeId(for vc: AnyObject) -> String {
    "vc@" + String(UInt(bitPattern: ObjectIdentifier(vc).hashValue), radix: 16)
}
