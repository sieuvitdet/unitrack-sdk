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

        // Co-resident mode: nếu process có native UniTrack module ngoài (FPT
        // Life host SPM "UniTrack"), forward mọi call qua HostProxy → cùng
        // singleton native (cùng session_id, cùng SQLite, cùng provider list).
        // KHÔNG dùng module-local UniTrack ở Plugin để tránh tạo singleton thứ 2.
        if UniTrackHostProxy.isCoResident {
            handleCoResident(call, args: args, result: result)
            return
        }

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

    // MARK: - Co-resident handler (forward qua HostProxy → singleton native)
    //
    // Khi process có cả native UniTrack SPM lẫn Flutter plugin, mọi MethodChannel
    // call route vào đây để forward về singleton NATIVE qua ObjC runtime. Plugin
    // KHÔNG init UniTrack module-local → zero singleton trùng, zero SQLite trùng,
    // zero session_id trùng.
    private func handleCoResident(_ call: FlutterMethodCall,
                                  args: [String: Any],
                                  result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            // No-op — native side đã init từ host app code. Plugin chỉ piggyback.
            // Vẫn forward registerLayer để native swizzler biết Flutter có mặt.
            UniTrackHostProxy.registerLayer(Int(UniTrackLayer.flutter.rawValue))
            UniTrackPluginLog.info("co-resident: skip Flutter init, piggyback native UniTrack singleton")
            result(nil)
        case "identify":
            let uid = args["userId"] as? String ?? ""
            // Encode traits as JSON cho ObjC bridge
            let traits = dict(from: args["traits"])
            let json = (try? JSONSerialization.data(withJSONObject: traits))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            UniTrackHostProxy.identify(userId: uid, traitsJson: json)
            result(nil)
        case "reset":
            UniTrackHostProxy.reset(); result(nil)
        case "track":
            let event = args["event"] as? String ?? ""
            let props = dict(from: args["props"])
            UniTrackHostProxy.track(event, properties: props)
            result(nil)
        case "setScreen":
            UniTrackHostProxy.setScreen(args["name"] as? String ?? "")
            result(nil)
        case "registerLayer":
            UniTrackHostProxy.registerLayer(args["layer"] as? Int ?? Int(UniTrackLayer.flutter.rawValue))
            result(nil)
        case "setScreenForLayer":
            UniTrackHostProxy.setScreenForLayer(
                args["name"] as? String ?? "",
                layer: args["layer"] as? Int ?? Int(UniTrackLayer.flutter.rawValue))
            result(nil)
        case "flush":           UniTrackHostProxy.flush(); result(nil)
        case "setEnabled":      UniTrackHostProxy.setEnabled(args["enabled"] as? Bool ?? true); result(nil)
        case "currentSessionId":  result(UniTrackHostProxy.currentSessionId())
        case "sessionIndex":      result(UniTrackHostProxy.sessionIndex())
        case "previousSessionId": result(UniTrackHostProxy.previousSessionId())
        case "rotateSession":     UniTrackHostProxy.rotateSession(); result(nil)
        // claimSubtree / releaseSubtree không exposed qua ObjC bridge ở proxy
        // hiện tại (LayerRegistry là internal). Fall back no-op để Dart không
        // crash khi gọi — registerLayer đã đủ cho dedup baseline.
        case "claimSubtree", "releaseSubtree":
            result(nil)
        default:
            // Mọi method khác (pendingEventCounts, attachFirebaseAdapter,
            // applicationContext, …) chưa wire qua ObjC bridge. Trả không
            // implemented để Dart side fallback hành vi cũ. Sẽ mở rộng khi
            // có nhu cầu thực tế.
            UniTrackPluginLog.warn("co-resident: method '\(call.method)' chưa bridge → not implemented")
            result(FlutterMethodNotImplemented)
        }
    }
}
