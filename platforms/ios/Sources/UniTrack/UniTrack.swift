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

        /// Event names emitted on screen transition. Core fires three events
        /// per transition: screenEndEvent for the previous screen (with
        /// dwell_ms), `screen_view` (always, back-compat), then
        /// screenStartEvent for the new screen. Override these per project
        /// from the portal `sdk_config` so the wire taxonomy matches the
        /// product spec (e.g. "screen_viewed" / "screen_exited").
        public var screenStartEvent: String?    = nil
        public var screenEndEvent:   String?    = nil
        /// Event name fired by the viewDidAppear swizzler with load_ms.
        /// Default `screen_load_completed`; override via portal
        /// `sdk_config.screen_load_event`.
        public var screenLoadEvent:  String     = "screen_load_completed"

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

    // Per-event NSLog of what flows through UniTrack/Snowplow/Firebase. Default ON
    // so integrators see traffic immediately while wiring the SDK up; flip to OFF
    // (UniTrack.verboseLogging = false) before shipping a release build.
    public static var verboseLogging: Bool = true

    /// Resolved event name for the swizzler's screen_load_completed fire.
    /// Initialised from `config.screenLoadEvent` on initialize() so swizzlers
    /// (which have no direct config access) can read a single static.
    internal static var screenLoadEventName: String = "screen_load_completed"

    /// Provider/helper code uses this instead of NSLog directly so the integrator
    /// can mute every log line with one flag. Format is the same as NSLog.
    public static func log(_ format: String, _ args: CVarArg...) {
        guard verboseLogging else { return }
        withVaList(args) { NSLogv(format, $0) }
    }

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

    // ── W3C distributed tracing ────────────────────────────────────────────
    //
    // Apps install the tracing config from remote_config.tracing — same shape
    // as Android UniTrack.setTracing(). Tracing on iOS is wired through
    // UniTrackURLProtocol; this setter just stores the snapshot the protocol
    // reads. allowlistHosts is fail-closed: empty list ⇒ never inject (so
    // `traceparent` never leaks to Firebase / Maps / CDNs).
    private var tracingEnabledFlag: Bool      = false
    private var tracingHeaderName:  String    = "traceparent"
    private var tracingAllowlist:   [String]  = []
    private var tracingSampledFlag: Bool      = true

    public static func setTracing(enabled: Bool,
                                  headerName: String = "traceparent",
                                  allowlistHosts: [String] = [],
                                  sampled: Bool = true) {
        shared.tracingEnabledFlag = enabled
        shared.tracingHeaderName  = headerName.isEmpty ? "traceparent" : headerName
        shared.tracingAllowlist   = allowlistHosts
        shared.tracingSampledFlag = sampled
    }

    /// Snapshot the URLProtocol reads on each outbound request. Internal so
    /// the protocol can fetch the latest config without locking.
    internal struct TracingSnapshot {
        let enabled: Bool
        let headerName: String
        let allowlist: [String]
        let sampled: Bool
    }
    internal static func tracingSnapshot() -> TracingSnapshot {
        TracingSnapshot(
            enabled:    shared.tracingEnabledFlag,
            headerName: shared.tracingHeaderName,
            allowlist:  shared.tracingAllowlist,
            sampled:    shared.tracingSampledFlag)
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
        let name = event
        let props = properties
        // Visibility — one line per event so the developer can see what's
        // about to be forwarded and to which provider list. Gated by
        // UniTrack.verboseLogging so a release build can mute it.
        if UniTrack.verboseLogging {
            let provNames = shared.providers.map { String(describing: type(of: $0)) }.joined(separator: ",")
            UniTrack.log("[UniTrack] track event=\"%@\" props=%@ → providers=[%@]",
                         name, UniTrack.jsonString(from: props) ?? "{}",
                         provNames.isEmpty ? "(none)" : provNames)
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

    /// Notification received/opened/dismissed. state: foreground|background|silent.
    /// `notificationId` is the platform id (FCM messageId / iOS UNNotification
    /// id) so the portal can join the same push across deliver/open. `data` is
    /// the raw payload bag (FCM data dictionary, APNs userInfo).
    public static func trackNotification(state: String, action: String = "received",
                                         title: String? = nil, body: String? = nil,
                                         notificationId: String? = nil,
                                         data: [String: Any]? = nil) {
        var p: [String: Any] = ["state": state, "action": action]
        if let title = title { p["title"] = title }
        if let body = body { p["body"] = body }
        if let nid = notificationId, !nid.isEmpty { p["notification_id"] = nid }
        if let data = data, !data.isEmpty { p["data"] = data }
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

    // MARK: - W3C Trace Context

    /// One outbound HTTP call's identifying triple. `traceId` is 32 lowercase
    /// hex (128 bit), `spanId` is 16 lowercase hex (64 bit), and `header` is
    /// the ready-to-attach value for the `traceparent` request header.
    public struct Trace {
        public let traceId: String
        public let spanId:  String
        public let header:  String     // "00-<trace>-<span>-01"
    }

    /// Allocate a fresh trace_id + span_id pair. Cheap (one PRNG call) — safe
    /// to call per HTTP request.
    public static func newTrace(sampled: Bool = true) -> Trace {
        var ids = ut_new_trace()
        let traceId = withUnsafePointer(to: &ids.trace_id) {
            $0.withMemoryRebound(to: CChar.self, capacity: 33) { String(cString: $0) }
        }
        let spanId  = withUnsafePointer(to: &ids.span_id) {
            $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
        }
        var buf = [CChar](repeating: 0, count: 64)
        let n = ut_format_traceparent(&ids, sampled ? 1 : 0, &buf, buf.count)
        let header: String = n > 0 ? String(cString: buf) : ""
        return Trace(traceId: traceId, spanId: spanId, header: header)
    }

    // MARK: - Internal

    var contextHandle: OpaquePointer? { context }

    private func _initialize(apiKey: String, config: Config) {
        guard !isInitialized else {
            NSLog("[UniTrack] already initialized")
            return
        }

        // Wire taxonomy override into the swizzler bridge before installing
        // the swizzlers below — they read this static at fire time.
        if !config.screenLoadEvent.isEmpty {
            UniTrack.screenLoadEventName = config.screenLoadEvent
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

        // Pop any crash recovered at ut_init from the core. Core already
        // enqueued it to the offline queue (→ portal HTTP); this re-emits
        // through provider track() so Snowplow's convention helpers +
        // Firebase's sanitizer process it like a live crash.
        if let ctx = context {
            let cstr = ut_pop_recovered_crash(ctx)
            let json = cstr.map { String(cString: $0) } ?? ""
            if !json.isEmpty,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var props = dict
                props["recovered_on_launch"] = true
                if !providers.isEmpty {
                    UniTrack.log("[UniTrack] fan-out recovered crash to %d provider(s)",
                                 providers.count)
                    for p in providers { p.track("crash", props) }
                }
                // Stash for the Flutter plugin to forward up to Dart (the
                // Flutter app may host its own Dart-side providers that the
                // native provider fan-out above doesn't reach). Single-shot.
                Self.pendingRecoveredCrashForFlutter = props
            }
        }
    }

    /// Single-shot drain for the Flutter MethodChannel bridge. Returns the
    /// JSON-encoded recovered crash props (with `recovered_on_launch=true`)
    /// captured during initialize(), or nil if nothing to forward. Native
    /// iOS apps (UIKit / SwiftUI) don't need this; it exists so the Flutter
    /// plugin can push the same payload up the channel to Dart-side providers.
    private static var pendingRecoveredCrashForFlutter: [String: Any]?
    public static func takeRecoveredCrashJsonForFlutter() -> String? {
        guard let props = pendingRecoveredCrashForFlutter else { return nil }
        pendingRecoveredCrashForFlutter = nil
        return UniTrack.jsonString(from: props)
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
        if let s = c.screenStartEvent, !s.isEmpty {
            parts.append("\"screen_start_event\":\"\(s)\"")
        }
        if let s = c.screenEndEvent, !s.isEmpty {
            parts.append("\"screen_end_event\":\"\(s)\"")
        }
        if let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first {
            let dbPath = docs.appendingPathComponent("unitrack.db").path
            parts.append("\"db_path\":\"\(dbPath)\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
