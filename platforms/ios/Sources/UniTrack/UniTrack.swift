// UniTrack.swift
//
// Public Swift API for the UniTrack SDK on iOS.
// Partners only call UniTrack.initialize(apiKey:). Everything else
// is automatic via swizzling installed in initialize().

import Foundation
import UIKit

public final class UniTrack {

    public struct Config {
        public var endpoint: String?            = nil
        public var batchSize: Int               = 50
        public var flushIntervalMs: Int         = 5000
        public var samplingRate: Double         = 1.0
        public var autoCapture: Bool            = true
        public var trackScreens: Bool           = true
        public var trackTaps: Bool              = true
        public var trackNetwork: Bool           = true
        public var trackMemoryWarnings: Bool    = true
        public var logLevel: LogLevel           = .warn

        public init() {}
    }

    public enum LogLevel: Int32 {
        case error = 0, warn = 1, info = 2, debug = 3
    }

    public static let shared = UniTrack()

    private var context: OpaquePointer?
    private let coldStartAt = Date()
    private(set) public var isInitialized = false

    private init() {}

    // MARK: - Public API

    /// Initialize the SDK. Call once at app startup (typically in
    /// `application(_:didFinishLaunchingWithOptions:)`).
    public static func initialize(apiKey: String, config: Config = Config()) {
        shared._initialize(apiKey: apiKey, config: config)
    }

    public static func identify(userId: String, traits: [String: Any] = [:]) {
        guard let ctx = shared.context else { return }
        ut_identify(ctx, userId,
                    UniTrack.jsonString(from: traits) ?? "{}")
    }

    public static func reset() {
        guard let ctx = shared.context else { return }
        ut_reset(ctx)
    }

    public static func track(_ event: String, properties: [String: Any] = [:]) {
        guard let ctx = shared.context else { return }
        ut_track(ctx, event,
                 UniTrack.jsonString(from: properties) ?? "{}")
    }

    public static func setScreen(_ name: String) {
        guard let ctx = shared.context else { return }
        ut_set_screen(ctx, name)
    }

    public static func flush() {
        guard let ctx = shared.context else { return }
        ut_flush(ctx)
    }

    public static func setEnabled(_ enabled: Bool) {
        guard let ctx = shared.context else { return }
        ut_set_enabled(ctx, enabled ? 1 : 0)
    }

    // MARK: - Internal

    var contextHandle: OpaquePointer? { context }

    private func _initialize(apiKey: String, config: Config) {
        guard !isInitialized else {
            NSLog("[UniTrack] already initialized")
            return
        }

        let cfgJson = UniTrack.buildConfigJson(config)
        context = ut_init(apiKey, cfgJson, UT_PLATFORM_IOS)
        guard context != nil else {
            NSLog("[UniTrack] ut_init failed")
            return
        }
        ut_set_log_level(context, ut_log_level(rawValue: UInt32(config.logLevel.rawValue)))

        // Install the HTTP transport callback (uses URLSession).
        HTTPBridge.install(into: context!)

        if config.autoCapture {
            if config.trackScreens         { ViewControllerSwizzler.install() }
            if config.trackTaps            { ControlSwizzler.install() }
            if config.trackNetwork         { UniTrackURLProtocol.install() }
            if config.trackMemoryWarnings  { MemoryWarningObserver.install() }
            AppLifecycleObserver.install()
        }

        // Cold-start metric
        let coldMs = Int(Date().timeIntervalSince(coldStartAt) * 1000)
        ut_log_app_start(context, coldMs)
        isInitialized = true
    }

    // MARK: - Helpers

    static func jsonString(from dict: [String: Any]) -> String? {
        guard !dict.isEmpty else { return "{}" }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    private static func buildConfigJson(_ c: Config) -> String {
        var parts: [String] = []
        if let ep = c.endpoint { parts.append("\"endpoint\":\"\(ep)\"") }
        parts.append("\"batch_size\":\(c.batchSize)")
        parts.append("\"flush_interval_ms\":\(c.flushIntervalMs)")
        parts.append("\"sampling_rate\":\(c.samplingRate)")
        parts.append("\"auto_capture\":\(c.autoCapture)")
        if let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first {
            let dbPath = docs.appendingPathComponent("unitrack.db").path
            parts.append("\"db_path\":\"\(dbPath)\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
