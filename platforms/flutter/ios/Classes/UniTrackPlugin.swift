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

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "unitrack",
                                           binaryMessenger: registrar.messenger())
        let instance = UniTrackPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
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

        case "addHttpProvider":
            let id        = (args["id"] as? String) ?? "http"
            let endpoint  = (args["endpoint"] as? String) ?? ""
            let fmtIdx    = (args["format"] as? Int) ?? 0
            let headers   = (args["headers"] as? [String: String]) ?? [:]
            let batchSize = (args["batchSize"] as? Int) ?? 50
            let flushMs   = (args["flushIntervalMs"] as? Int) ?? 30_000
            let format: PayloadFormat = PayloadFormat(rawValue: fmtIdx) ?? .jsonSingle
            if let url = URL(string: endpoint) {
                UniTrack.addHttpProvider(
                    id: id, endpoint: url, format: format,
                    headers: headers, batchSize: batchSize,
                    flushInterval: TimeInterval(flushMs) / 1000
                )
            }
            result(nil)

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
