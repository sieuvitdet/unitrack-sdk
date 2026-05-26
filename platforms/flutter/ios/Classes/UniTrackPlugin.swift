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

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "unitrack",
                                           binaryMessenger: registrar.messenger())
        let instance = UniTrackPlugin()
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
            UniTrack.initialize(apiKey: apiKey, config: cfg)
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

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
