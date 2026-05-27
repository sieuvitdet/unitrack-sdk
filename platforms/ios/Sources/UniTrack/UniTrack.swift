// UniTrack.swift
//
// Public Swift API for the UniTrack SDK on iOS.
// Partners only call UniTrack.initialize(apiKey:). Everything else
// is automatic via swizzling installed in initialize().

import Foundation
import UIKit
// C core symbols come from the UniTrackCore module under SPM (two targets).
// Under CocoaPods the pod is a single module and the C API is exposed via the
// umbrella header, so the module does not exist there — hence the guard.
#if canImport(UniTrackCore)
import UniTrackCore
#endif

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

        /// Emit session_start / session_end boundary events so the portal can
        /// reconstruct each session's journey. sessionTimeoutMs is the
        /// inactivity/background window after which a session is closed.
        public var journeyCapture: Bool         = true
        public var sessionTimeoutMs: Int        = 1_800_000  // 30 min

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

    // Registered third-party providers (Snowplow, Firebase, …). Every event is
    // forwarded to each one. Empty by default — core has zero such dependencies.
    private var providers: [AnalyticsProvider] = []

    // MARK: - Public API

    /// Register a provider to also receive every event. Call BEFORE initialize();
    /// if called afterwards, the provider is initialized immediately.
    public static func addProvider(_ provider: AnalyticsProvider) {
        shared.providers.append(provider)
        if shared.isInitialized {
            provider.initializeProvider()
        }
    }

    // Run a closure against every provider, isolating failures so one bad
    // provider never breaks the main pipeline.
    private static func forEachProvider(_ action: (AnalyticsProvider) -> Void) {
        for p in shared.providers { action(p) }
    }

    // MARK: - Event rewrite rules (Phase 2 — config-driven)
    //
    // A rule rewrites an auto-captured event (tap / screen_view / network_request)
    // into a business event name + extra props, based on the portal config. This
    // lets the app emit a meaningful business event WITHOUT a hand-written helper:
    // e.g. a tap with element_key "stream_start" on screen "LiveStreamViewController"
    // becomes "camera_stream_started". Rules come from the remote config.
    public struct EventRule {
        public var matchEvent: String          // raw event to match (e.g. "tap")
        public var matchScreen: String?         // optional screen filter
        public var matchElementKey: String?     // optional element_key filter
        public var toName: String               // business event name to emit
        public var addProps: [String: Any]      // static props merged in
        public init(matchEvent: String, matchScreen: String? = nil,
                    matchElementKey: String? = nil, toName: String,
                    addProps: [String: Any] = [:]) {
            self.matchEvent = matchEvent; self.matchScreen = matchScreen
            self.matchElementKey = matchElementKey; self.toName = toName
            self.addProps = addProps
        }
    }
    private var eventRules: [EventRule] = []

    /// Install rewrite rules (from remote config). Call before/after init.
    public static func setEventRules(_ rules: [EventRule]) {
        shared.eventRules = rules
    }

    // Returns the rewritten (name, properties) for an event, or nil if no rule
    // matches. First matching rule wins.
    private func applyRules(_ event: String, _ properties: [String: Any]) -> (String, [String: Any])? {
        let screen = (properties["screen"] as? String) ?? (properties["screen_name"] as? String)
        let elem   = properties["element_key"] as? String
        for r in eventRules where r.matchEvent == event {
            if let s = r.matchScreen, s != screen { continue }
            if let e = r.matchElementKey, e != elem { continue }
            var props = properties
            for (k, v) in r.addProps { props[k] = v }
            return (r.toName, props)
        }
        return nil
    }

    /// Initialize the SDK. Call once at app startup (typically in
    /// `application(_:didFinishLaunchingWithOptions:)`).
    public static func initialize(apiKey: String, config: Config = Config()) {
        shared._initialize(apiKey: apiKey, config: config)
    }

    public static func identify(userId: String, traits: [String: Any] = [:]) {
        forEachProvider { $0.setUser(userId, traits) }
        guard let ctx = shared.context else { return }
        ut_identify(ctx, userId,
                    UniTrack.jsonString(from: traits) ?? "{}")
    }

    public static func reset() {
        forEachProvider { $0.setUser(nil, [:]) }
        guard let ctx = shared.context else { return }
        ut_reset(ctx)
    }

    public static func track(_ event: String, properties: [String: Any] = [:]) {
        // Phase 2: a config rule may rewrite an auto-captured event into a
        // business event (name + extra props) before it goes anywhere.
        var name = event
        var props = properties
        if let (rewritten, rewrittenProps) = shared.applyRules(event, properties) {
            name = rewritten
            props = rewrittenProps
        }
        // Forward to every registered provider (Snowplow, Firebase, …).
        forEachProvider { $0.track(name, props) }
        guard let ctx = shared.context else { return }
        ut_track(ctx, name,
                 UniTrack.jsonString(from: props) ?? "{}")
    }

    public static func setScreen(_ name: String) {
        forEachProvider { $0.setScreen(name) }
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

    /// Exclude a URL (matched by substring, e.g. a host) from network
    /// auto-capture. Providers call this for their own collector/upload URLs so
    /// the SDK never captures-and-re-forwards its own analytics traffic.
    public static func excludeFromNetworkCapture(urlContaining substring: String) {
        UniTrackURLProtocol.excludeURL(containing: substring)
    }

    // MARK: - Semantic events (Phase 3)

    /// Notification received/opened. state: foreground|background|silent.
    public static func trackNotification(state: String, action: String = "received",
                                         title: String? = nil, body: String? = nil) {
        var p: [String: Any] = ["state": state, "action": action]
        if let title = title { p["title"] = title }
        if let body = body { p["body"] = body }
        track("notification", properties: p)
    }

    public static func trackWebViewOpen(_ url: String) {
        track("webview_open", properties: ["url": hostPath(url)])
    }

    public static func trackDeeplink(_ url: String, source: String? = nil) {
        var p: [String: Any] = ["url": hostPath(url)]
        if let source = source { p["source"] = source }
        track("deeplink", properties: p)
    }

    public static func trackThirdPartyOpen(_ name: String) {
        track("third_party_open", properties: ["target": name])
    }

    private static func hostPath(_ url: String) -> String {
        guard let u = URL(string: url) else { return url }
        if let scheme = u.scheme, let host = u.host { return "\(scheme)://\(host)\(u.path)" }
        return u.path
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

        // Attach device/app metadata to every event (model, OS, app version,
        // locale, …) — collected once here.
        ut_set_device_info(context, DeviceInfo.json())

        // Install the HTTP transport callback (uses URLSession).
        HTTPBridge.install(into: context!)

        if config.autoCapture {
            if config.trackScreens         { ViewControllerSwizzler.install() }
            if config.trackTaps            { ControlSwizzler.install() }
            if config.trackNetwork {
                UniTrackURLProtocol.install()
                // Don't capture the SDK's own uploads (avoids a feedback loop:
                // upload → captured as network_request → forwarded → captured…).
                if let ep = config.endpoint, let host = URL(string: ep)?.host {
                    UniTrackURLProtocol.excludeURL(containing: host)
                }
            }
            if config.trackMemoryWarnings  { MemoryWarningObserver.install() }
            AppLifecycleObserver.install()
        }

        // Cold-start metric
        let coldMs = Int(Date().timeIntervalSince(coldStartAt) * 1000)
        ut_log_app_start(context, coldMs)
        isInitialized = true

        // Bring up any providers registered before initialize().
        for p in providers { p.initializeProvider() }
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
        parts.append("\"journey_capture\":\(c.journeyCapture)")
        parts.append("\"session_timeout_ms\":\(c.sessionTimeoutMs)")
        if let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first {
            let dbPath = docs.appendingPathComponent("unitrack.db").path
            parts.append("\"db_path\":\"\(dbPath)\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
