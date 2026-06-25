// UniTrackPlugin.swift — Flutter iOS plugin bridge.
//
// Forwards MethodChannel calls to the UniTrack Swift SDK. The native SDK
// source (Swift + C++ core) is vendored into this same pod/module, so the
// `UniTrack` type is available directly with no import.
//
// This replaces the original Objective-C bridge, which assumed an @objc API
// that the pure-Swift SDK does not expose.

import Flutter
import UIKit

public class UniTrackPlugin: NSObject, FlutterPlugin {

    // Held so we can push native-originating events (e.g. recovered crash from
    // a previous launch) back to Dart on the same channel the app uses.
    private var channel: FlutterMethodChannel?
    // Subscription token into NativeScreenChannel so we can release on dealloc.
    // Multiple plugin instances would each subscribe; one subscription per
    // instance keeps the API simple.
    private var nativeScreenToken: Int?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "unitrack",
                                           binaryMessenger: registrar.messenger())
        let instance = UniTrackPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Reverse direction: when the native swizzler emits a screen for a
        // non-Flutter VC (vd Flutter app opened a UIKit screen via plugin),
        // tell Dart so its `currentScreen` mirror is correct for tap attribution.
        // Self-broadcasts (layer == .flutter) are ignored — Dart already knows
        // about its own screens.
        instance.nativeScreenToken = NativeScreenChannel.subscribe { [weak instance] screen, layer in
            guard layer != .flutter else { return }
            DispatchQueue.main.async {
                instance?.channel?.invokeMethod(
                    "onNativeScreen",
                    arguments: ["name": screen, "layer": Int(layer.rawValue)]
                )
            }
        }
    }

    deinit {
        if let t = nativeScreenToken { NativeScreenChannel.unsubscribe(t) }
    }

    private func dict(from json: Any?) -> [String: Any] {
        guard let s = json as? String,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initialize":
            let apiKey = args["apiKey"] as? String ?? ""
            let c = dict(from: args["config"])
            var cfg = UniTrack.Config()
            if let ep = c["endpoint"] as? String { cfg.endpoint = ep }
            if let v = c["batchSize"] as? Int { cfg.batchSize = v }
            if let v = c["flushIntervalMs"] as? Int { cfg.flushIntervalMs = v }
            if let v = c["samplingRate"] as? Double { cfg.samplingRate = v }
            if let v = c["autoCapture"] as? Bool { cfg.autoCapture = v }
            if let v = c["trackScreens"] as? Bool { cfg.trackScreens = v }
            if let v = c["trackTaps"] as? Bool { cfg.trackTaps = v }
            if let v = c["trackNetwork"] as? Bool { cfg.trackNetwork = v }
            if let v = c["journeyCapture"] as? Bool { cfg.journeyCapture = v }
            if let v = c["sessionTimeoutMs"] as? Int { cfg.sessionTimeoutMs = v }
            if let v = c["screenLoadEvent"] as? String, !v.isEmpty { cfg.screenLoadEvent = v }
            UniTrack.initialize(apiKey: apiKey, config: cfg)

            // After initialize(), the native UniTrack has already popped the
            // recovered crash from core and fanned it out to native providers.
            // Forward the same JSON up to Dart so Dart-side providers
            // (e.g. unitrack_snowplow Dart package) also see it. Single-shot.
            if let json = UniTrack.takeRecoveredCrashJsonForFlutter() {
                self.channel?.invokeMethod("onRecoveredCrash", arguments: ["props": json])
            }
            result(nil)

        case "identify":
            UniTrack.identify(userId: args["userId"] as? String ?? "",
                              traits: dict(from: args["traits"]))
            result(nil)

        case "reset":
            UniTrack.reset()
            result(nil)

        case "track":
            UniTrack.track(args["event"] as? String ?? "",
                           properties: dict(from: args["props"]))
            result(nil)

        case "setScreen":
            UniTrack.setScreen(args["name"] as? String ?? "")
            result(nil)

        // ── Cross-language layer registry ───────────────────────────────────
        // Forwarded by the Dart UniTrack.initialize so the Swift swizzler can
        // detect Flutter is present and yield its FlutterViewController to us.
        case "registerLayer":
            // Dart sends the raw bitmask (UT_LAYER_FLUTTER = 4) so we can
            // accept either Flutter or, in mixed setups, also RN if someone
            // routes through this same channel. Defaults to Flutter.
            let raw = UInt32(args["layer"] as? Int ?? Int(UniTrackLayer.flutter.rawValue))
            if let layer = UniTrackLayer(rawValue: raw) {
                LayerRegistry.register(layer)
            }
            result(nil)

        case "claimSubtree":
            let id  = args["subtreeId"] as? String ?? ""
            let raw = UInt32(args["layer"] as? Int ?? Int(UniTrackLayer.flutter.rawValue))
            if !id.isEmpty, let layer = UniTrackLayer(rawValue: raw) {
                LayerRegistry.claim(subtree: id, by: layer)
            }
            result(nil)

        case "releaseSubtree":
            let id = args["subtreeId"] as? String ?? ""
            if !id.isEmpty { LayerRegistry.release(subtree: id) }
            result(nil)

        // setScreenForLayer goes through the binding's full fan-out (providers,
        // dwell tracking) so a Flutter-originated screen looks identical to a
        // native one from the portal's perspective — just tagged so core's
        // cross-layer dedup knows who emitted it.
        case "setScreenForLayer":
            let name = args["name"] as? String ?? ""
            let raw  = UInt32(args["layer"] as? Int ?? Int(UniTrackLayer.flutter.rawValue))
            let layer = UniTrackLayer(rawValue: raw) ?? .flutter
            UniTrack.setScreen(name, layer: layer)
            result(nil)

        case "flush":
            UniTrack.flush()
            result(nil)

        case "setEnabled":
            UniTrack.setEnabled(args["enabled"] as? Bool ?? true)
            result(nil)

        // ── Session API parity with iOS Swift / Android Kotlin ─────────────
        case "currentSessionId":
            result(UniTrack.currentSessionId())
        case "sessionIndex":
            // Swift returns Int; standard codec encodes it as Dart int.
            result(UniTrack.sessionIndex())
        case "previousSessionId":
            result(UniTrack.previousSessionId())
        case "rotateSession":
            UniTrack.rotateSession(); result(nil)

        // Offline queue snapshot by event_name. UniTrack.pendingEventCounts
        // returns [String: Int] which the standard codec encodes as a Dart
        // Map<String,int>.
        case "pendingEventCounts":
            result(UniTrack.pendingEventCounts())

        // ── Provider Adapters (Phase 6) ──────────────────────────────────
        case "pendingProviderRetryCount":
            result(UniTrack.pendingProviderRetryCount())

        case "attachFirebaseAdapter":
            UniTrack.attachFirebaseAdapter()
            // Echo back whether the adapter actually attached so Dart can
            // surface a "Firebase not linked" log when the host app hasn't
            // pulled in FIRAnalytics yet.
            result(NSClassFromString("FIRAnalytics") != nil)

        // Subscribe / unsubscribe the flush-success callback. Dart toggles
        // this when its onFlushCompleted listener is set / cleared.
        case "setFlushCallbackEnabled":
            let enabled = (args["enabled"] as? Bool) ?? false
            if enabled {
                UniTrack.onFlushCompleted { [weak self] counts in
                    // Hop to main: FlutterMethodChannel.invokeMethod is not
                    // safe off the platform thread.
                    DispatchQueue.main.async {
                        self?.channel?.invokeMethod("onFlushCompleted",
                                                    arguments: ["counts": counts])
                    }
                }
            } else {
                UniTrack.onFlushCompleted(nil)
            }
            result(nil)

        // Device / app metadata bag — same dict the native Snowplow provider
        // builds its application_context entity from. Empty before init.
        case "applicationContext":
            result(UniTrack.applicationContext())

        // Remote config resolver. Routes to the typed getter on the Swift
        // side based on a hint from Dart; the resolved value is returned as
        // the matching codec type so Dart's generic getRemoteValue<T> reads
        // it back without manual cast.
        case "getRemoteValue":
            let key  = (args["key"] as? String) ?? ""
            let kind = (args["type"] as? String) ?? "string"
            switch kind {
            case "bool":   result(UniTrack.getRemoteValue(key, default: false))
            case "int":    result(UniTrack.getRemoteValue(key, default: 0))
            case "double": result(UniTrack.getRemoteValue(key, default: 0.0))
            default:       result(UniTrack.getRemoteValue(key, default: ""))
            }

        // Session-stat sidebag mirrors Android. Same names so the Dart facade
        // is identical across both platforms.
        case "sessionScreenCount":   result(UniTrack.sessionScreenCount())
        case "sessionHadError":      result(UniTrack.sessionHadError())
        case "sessionHadCrash":      result(UniTrack.sessionHadCrash())
        case "incrementScreenCount": UniTrack.incrementScreenCount(); result(nil)
        case "markSessionError":     UniTrack.markSessionError();     result(nil)
        case "markSessionCrash":     UniTrack.markSessionCrash();     result(nil)
        case "resetSessionStats":    UniTrack.resetSessionStats();    result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
