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
    internal var providers: [AnalyticsProvider] = []

    // Snapshot of the device/app bag the core stamps onto every event. Lives
    // on the shared instance so providers building their own context entities
    // (vd Snowplow application_context) read the same source the wire payload
    // uses. Set inside initialize() right after ut_set_device_info().
    internal var cachedDeviceBag: [String: Any] = [:]

    // Session-stat snapshot tracked at the binding layer so AppLifecycleObserver
    // (and apps) can fire `session_ended` with duration + counters without
    // re-reading the core. The core owns session_id rotation; this is just a
    // sidebag the binding fills as it observes events.
    private let sessionStatLock = NSLock()
    private var sessionStartedAtSnapshot: Date?
    private var sessionScreenCountSnapshot: Int = 0
    private var sessionHadErrorSnapshot: Bool = false
    private var sessionHadCrashSnapshot: Bool = false
    private var sessionTimeoutMsValue: Int = 1_800_000

    // App-supplied closure fired on every successful batch flush. Stored on
    // the singleton because the C callback bridge needs a stable pointer; we
    // hand the singleton to ut_set_flush_callback as `userdata` and read this
    // back inside the thunk. nil when no handler is set.
    fileprivate var flushSuccessHandler: (([String: Int]) -> Void)?

    // Last screen passed to setScreen, used so the binding can fan out a
    // matching screen_exited/screen_viewed pair into providers (Snowplow,
    // Firebase). The C++ core fires the same boundary events into its HTTP
    // queue independently — these two paths intentionally stay in lockstep
    // so the portal log + the Snowplow collector see the same transitions.
    private let lastScreenLock = NSLock()
    private var lastScreen: String?
    private var lastScreenAt: Date?

    // Wire-event names for the screen boundary pair, sourced from
    // Config.screenStartEvent / screenEndEvent (typically set from portal
    // sdk_config.screen_start_event / screen_end_event). Default to the
    // legacy "screen_view" so an app that never sets them keeps the old
    // behaviour. Updated inside initialize().
    private var screenStartEventName: String = "screen_view"
    private var screenEndEventName:   String = "screen_view"
    private var screenLifecycleEnabled: Bool = true

    // App-supplied closure invoked once each time the app comes back to
    // foreground AND the throttle window has elapsed (default 5 min). Used by
    // the app integration layer (vd FSDKTracking) to re-fetch portal remote
    // config without baking the fetch URL/api_key into the SDK core. The
    // SDK itself stays scoped to "track events"; what to refresh on
    // foreground is a host decision.
    fileprivate var appForegroundHandler: (() -> Void)?
    fileprivate var foregroundThrottleSec: TimeInterval = 5 * 60
    fileprivate var lastForegroundCallback: Date?

    // MARK: - Session helpers (used by AppLifecycleObserver + app code)

    /// Current session id (UUID v4). Empty before initialize().
    public static func currentSessionId() -> String {
        guard let ctx = shared.context else { return "" }
        guard let cstr = ut_current_session_id(ctx) else { return "" }
        return String(cString: cstr)
    }

    /// Lifetime session counter. Persists across launches — 1 on first install,
    /// +1 per timeout rotation. App stamps this on session_started events so
    /// the value survives app kill (vs a local static var which resets to 1
    /// every cold start). Returns 0 before initialize().
    public static func sessionIndex() -> Int {
        guard let ctx = shared.context else { return 0 }
        return Int(ut_current_session_index(ctx))
    }

    /// UUID of the previous (just-closed) session, or empty on the very first
    /// session after install. Pair with sessionIndex() when emitting
    /// session_started so backends can chain consecutive sessions.
    public static func previousSessionId() -> String {
        guard let ctx = shared.context else { return "" }
        guard let cstr = ut_previous_session_id(ctx) else { return "" }
        return String(cString: cstr)
    }

    /// Force a session rotation right now. Bumps sessionIndex(), mints a new
    /// currentSessionId(), stamps the just-closed session as previousSessionId().
    ///
    /// Call this from app boundaries the timeout doesn't model:
    ///   • Logout / switch account
    ///   • App-level "new conversation" / "new transaction" handoffs
    ///   • Test code that wants to verify session_index increments without
    ///     waiting for the 30-min inactivity timeout
    ///
    /// After this call, the next session_started event the app fires will
    /// carry the bumped index + previous session id automatically.
    public static func rotateSession() {
        guard let ctx = shared.context else { return }
        ut_rotate_session(ctx)
    }

    /// Snapshot of events still sitting in the offline queue, grouped by raw
    /// event_name. Returns `["ev_click": 3, "ev_result": 2]` for the demo UI
    /// that shows "Saved 3 ev_click, 2 ev_result" while the device is offline.
    /// Empty dict on queue empty or before init.
    ///
    /// Cheap (single SQLite scan over the payload column). Safe to call on any
    /// thread but don't poll it more than ~1Hz — the offline queue can hold
    /// up to maxQueueSize rows (default 10k).
    public static func pendingEventCounts() -> [String: Int] {
        guard let ctx = shared.context else { return [:] }
        let cstr = ut_pending_event_counts(ctx)
        let json = cstr.map { String(cString: $0) } ?? "{}"
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return [:]
        }
        return obj
    }

    /// Fires after each successful batch upload with the per-event_name
    /// breakdown of that batch (vd `["ev_click": 3, "ev_result": 2]`).
    /// Apps use this to pop a toast during real-device offline testing
    /// (airplane mode → tap around → mạng lại → toast).
    ///
    /// The handler is invoked on a background worker thread — hop to main
    /// before touching UIKit. Pass `nil` to clear. Replacing a previously
    /// set handler is allowed; only the latest survives.
    public static func onFlushCompleted(_ handler: (([String: Int]) -> Void)?) {
        shared.flushSuccessHandler = handler
        guard let ctx = shared.context else { return }
        if handler == nil {
            ut_set_flush_callback(ctx, nil, nil)
            return
        }
        // userdata = shared instance (immortal singleton) — safe to pass as an
        // unretained pointer. The thunk reads `flushSuccessHandler` off it,
        // so we don't need to capture the closure inside a Box ourselves.
        let unmanaged = Unmanaged.passUnretained(shared).toOpaque()
        ut_set_flush_callback(ctx, { (cjson, ud) in
            guard let cjson = cjson, let ud = ud else { return }
            let s = String(cString: cjson)
            let owner = Unmanaged<UniTrack>.fromOpaque(ud).takeUnretainedValue()
            guard let h = owner.flushSuccessHandler,
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
            else { return }
            h(obj)
        }, unmanaged)
    }

    /// Register a closure invoked when the app comes back to foreground.
    /// Used by host integrations to refresh portal remote config (or any other
    /// startup-bound resource) without baking the fetch into the SDK core.
    ///
    /// Throttled by `throttleSeconds` (default 5 min) so a user that taps in
    /// and out of the app every 30 seconds doesn't trigger N config fetches.
    /// The first foreground after `initialize()` does NOT fire (cold start
    /// already fetched). Subsequent didBecomeActive events trigger only when
    /// at least `throttleSeconds` have passed since the previous callback.
    ///
    /// Pass `handler = nil` to clear. Set on the main thread.
    public static func onAppForeground(throttleSeconds: TimeInterval = 5 * 60,
                                       _ handler: (() -> Void)?) {
        shared.appForegroundHandler   = handler
        shared.foregroundThrottleSec  = throttleSeconds
        shared.lastForegroundCallback = Date()   // seed so the cold-start foreground doesn't fire
    }

    /// Internal hook called by AppLifecycleObserver from the didBecomeActive
    /// notification. Public so the observer can reach it from another file in
    /// the same module — apps don't need to call this.
    public static func _fireForegroundIfThrottleElapsed() {
        guard let handler = shared.appForegroundHandler else { return }
        let now = Date()
        if let last = shared.lastForegroundCallback,
           now.timeIntervalSince(last) < shared.foregroundThrottleSec {
            return
        }
        shared.lastForegroundCallback = now
        handler()
    }

    /// When the active session started (monotonic clock-based). Nil before init.
    public static func sessionStartedAt() -> Date? {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        return shared.sessionStartedAtSnapshot
    }

    /// Inactivity window after which the core rotates the session.
    public static func sessionTimeoutMs() -> Int {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        return shared.sessionTimeoutMsValue
    }

    /// Lightweight per-session counters the app can opt into so session_ended
    /// carries useful business data. Apps call incrementScreenCount() when a
    /// new screen mounts, markError()/markCrash() at the appropriate spots.
    public static func sessionScreenCount() -> Int {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        return shared.sessionScreenCountSnapshot
    }
    public static func sessionHadError() -> Bool {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        return shared.sessionHadErrorSnapshot
    }
    public static func sessionHadCrash() -> Bool {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        return shared.sessionHadCrashSnapshot
    }

    public static func incrementScreenCount() {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        shared.sessionScreenCountSnapshot += 1
    }
    public static func markSessionError() {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        shared.sessionHadErrorSnapshot = true
    }
    public static func markSessionCrash() {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        shared.sessionHadCrashSnapshot = true
    }
    /// Reset the per-session counters — typically called from the app's own
    /// session_started handler after the core rotates (the binding doesn't
    /// auto-reset because that would race with mid-event observers).
    public static func resetSessionStats() {
        shared.sessionStatLock.lock(); defer { shared.sessionStatLock.unlock() }
        shared.sessionScreenCountSnapshot = 0
        shared.sessionHadErrorSnapshot = false
        shared.sessionHadCrashSnapshot = false
        shared.sessionStartedAtSnapshot = Date()
    }

    /// Returns the device/app metadata bag (platform, app_version, network_*,
    /// device_*) captured at init time. SnowplowProvider attaches this as the
    /// `application_context` entity — kept public so apps that build their own
    /// providers can do the same without re-running the platform queries.
    public static func applicationContext() -> [String: Any] {
        return shared.cachedDeviceBag
    }

    /// Parse the JSON object the C core consumes back into a Swift dict for
    /// in-process consumers. Returns an empty bag on malformed input.
    fileprivate static func parseDeviceBag(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

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
    ///
    /// Long payloads (vd: Snowplow envelope JSON ~3-10KB) get **chunked** so
    /// the os_log unified-logging backend doesn't truncate them at ~1024 chars
    /// — NSLog under the hood pipes through os_log, which trims long messages
    /// to keep the system log fast. We detect the long-message case by looking
    /// at the formatted string length and switch to per-line print() (raw
    /// stdout, no truncation) for the body. Header still goes through NSLog so
    /// it still shows in Console.app with the timestamp + process id prefix.
    public static func log(_ format: String, _ args: CVarArg...) {
        guard verboseLogging else { return }
        let formatted = withVaList(args) { NSString(format: format, arguments: $0) as String }
        emit(formatted)
    }

    /// Common log sink. NSLog for short (single-line) messages, chunked
    /// print() for long multi-line payloads. ~800 chars per chunk leaves
    /// headroom under both Xcode console (4KB) and unified logging (1024).
    internal static func emit(_ text: String) {
        let CHUNK = 800
        if text.count <= CHUNK && !text.contains("\n") {
            NSLog("%@", text)
            return
        }
        // Multi-line OR long: emit each line individually. If a single line
        // is still > CHUNK, split it further so we never lose a tail.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.count <= CHUNK {
                print(line)
            } else {
                var idx = line.startIndex
                while idx < line.endIndex {
                    let end = line.index(idx, offsetBy: CHUNK, limitedBy: line.endIndex) ?? line.endIndex
                    print(line[idx..<end])
                    idx = end
                }
            }
        }
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

    /// Drop every registered provider. Call this before re-adding providers
    /// when the host re-reads portal config (vd flavor switch, SSE-driven
    /// realtime refresh). Without it, a re-init would leave the OLD
    /// SnowplowProvider/FirebaseProvider in the fan-out list alongside the
    /// new one and every event would land twice — once at the old endpoint,
    /// once at the new one.
    public static func removeAllProviders() {
        shared.providers.removeAll()
    }

    /// Hot-reload the screen-lifecycle wire-event names (screenStartEvent,
    /// screenEndEvent, screenLoadEvent). UniTrack.initialize() is guarded
    /// `!isInitialized`, so when realtime config changes these wire names
    /// the binding-layer caches stay frozen unless we override them here.
    /// The C++ core's own copies (used by the HTTP queue) keep the cold-
    /// start values — fully resetting the core mid-flight risks dropping
    /// queued events, which the operator rarely wants. The provider
    /// fan-out path (Snowplow/Firebase) reads these caches AT FIRE TIME,
    /// so post-refresh events land under the new names on the providers.
    ///
    /// Pass nil for any field to keep its current value. Empty string ""
    /// resets to the default ("screen_view" / "screen_load_completed").
    public static func applyHotConfig(screenStartEvent: String? = nil,
                                      screenEndEvent:   String? = nil,
                                      screenLoadEvent:  String? = nil) {
        if let v = screenStartEvent {
            shared.screenStartEventName = v.isEmpty ? "screen_view" : v
        }
        if let v = screenEndEvent {
            shared.screenEndEventName   = v.isEmpty ? "screen_view" : v
        }
        if let v = screenLoadEvent {
            UniTrack.screenLoadEventName = v.isEmpty ? "screen_load_completed" : v
        }
        UniTrack.log("[UniTrack] hot-config screen events → start=%@ end=%@ load=%@",
                     shared.screenStartEventName,
                     shared.screenEndEventName,
                     UniTrack.screenLoadEventName)
    }

    /// Remove a single registered provider by identity. Useful when only one
    /// provider needs re-creating (vd just Firebase changed). Compares with
    /// ObjectIdentifier so an app can hold the original instance handle and
    /// pass it back without an Equatable conformance on the protocol.
    public static func removeProvider(_ provider: AnalyticsProvider) {
        shared.providers.removeAll { ObjectIdentifier($0) == ObjectIdentifier(provider) }
    }

    // Run a closure against every provider, isolating failures so one bad
    // provider never breaks the main pipeline.
    private static func forEachProvider(_ action: (AnalyticsProvider) -> Void) {
        for p in shared.providers { action(p) }
    }

    private static var pendingWorker: DispatchSourceTimer?

    /// Ack-aware fan-out. Calls `provider.send()` on every registered provider:
    ///   - .success → done
    ///   - .retry   → enqueue in PendingQueue for exponential-backoff retry
    ///   - .drop    → log and discard for that provider only
    ///
    /// Existing providers (Snowplow, Firebase) use the default `send()` impl
    /// from the protocol extension — they call `track()` and return .success.
    /// Custom HttpProvider overrides `send()` so UniTrack handles offline
    /// retry for any backend that doesn't ship its own SDK queue.
    private static func dispatchToProviders(_ name: String, _ props: [String: Any]) {
        var retryIds: [String] = []
        for p in shared.providers {
            let r = p.send(name, props)
            switch r {
            case .success: break
            case .retry:   retryIds.append(p.providerId)
            case .drop:    NSLog("[UniTrack] provider %@ dropped event \"%@\"",
                                 p.providerId, name)
            }
        }
        if !retryIds.isEmpty {
            PendingQueue.shared.enqueue(name: name, properties: props, providerIds: retryIds)
        }
    }

    static func startPendingWorker() {
        guard pendingWorker == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2.0)
        t.setEventHandler {
            let q = PendingQueue.shared
            q.trim()
            let batch = q.peek(max: 50)
            guard !batch.isEmpty else { return }
            let providers = shared.providers
            for row in batch {
                var successful: [String] = []
                var retrying:   [String] = []
                var dropped:    [String] = []
                let props = q.decodeProps(row)
                for provider in providers {
                    let bit = Int64(1) << q.bitFor(provider.providerId)
                    if row.pendingMask & bit == 0 { continue }
                    let r = provider.send(row.name, props)
                    switch r {
                    case .success: successful.append(provider.providerId)
                    case .retry:   retrying.append(provider.providerId)
                    case .drop:    dropped.append(provider.providerId)
                    }
                }
                q.ack(rowId: row.rowId, successful: successful,
                      retrying: retrying, dropped: dropped)
            }
        }
        t.resume()
        pendingWorker = t
    }

    /// Snapshot count of events waiting to retry. Demo/debug UIs.
    @objc public static func pendingProviderRetryCount() -> Int {
        PendingQueue.shared.count()
    }

    /// IDs of every registered HttpProvider — used by the remote-config
    /// reconciler (UniTrackRemoteConfig.applyHttpProviders) to compute the
    /// diff against Portal's desired list. Non-HttpProvider providers
    /// (Snowplow, Firebase, app-supplied) are excluded.
    public static func registeredHttpProviderIds() -> [String] {
        shared.providers.compactMap { ($0 as? HttpProvider)?.providerId }
    }

    /// Remove a provider whose providerId matches `id`. Used by the
    /// reconciler to drop providers no longer in Portal config + replace
    /// providers whose endpoint/headers/format changed (remove + add).
    /// No-op if no match — idempotent.
    public static func removeProvider(byId id: String) {
        shared.providers.removeAll { $0.providerId == id }
    }

    /// Convenience: attach the built-in `FirebaseAdapter` that stamps UniTrack
    /// `session_id` onto every Firebase Analytics event via reflection — 0
    /// import of Firebase in UniTrack core. App can be missing Firebase: this
    /// call is a no-op then. App can add Firebase tomorrow: this call starts
    /// working immediately, no rebuild.
    ///
    ///   UniTrack.attachFirebaseAdapter()
    public static func attachFirebaseAdapter() {
        if let a = FirebaseAdapter.create() { addProvider(a) }
    }

    /// Register a built-in `HttpProvider`. Internal — call site is the remote
    /// config reconciler (`UniTrackRemoteConfig.applyHttpProviders`). Portal
    /// is the only source of truth for custom HTTP backends so app code never
    /// needs (and isn't allowed) to wire one by hand.
    internal static func addHttpProvider(
        id: String,
        endpoint: URL,
        format: PayloadFormat = .jsonSingle,
        headers: [String: String] = [:],
        batchSize: Int = 50,
        flushInterval: TimeInterval = 30
    ) {
        addProvider(HttpProvider(
            id: id, endpoint: endpoint, format: format,
            headers: headers, batchSize: batchSize, flushInterval: flushInterval
        ))
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
        dispatchToProviders(name, props)
        guard let ctx = shared.context else { return }
        ut_track(ctx, name,
                 UniTrack.jsonString(from: props) ?? "{}")
    }

    public static func setScreen(_ name: String) {
        // Trace so a "screen_viewed/screen_exited not firing" bug is one log
        // line away from a diagnosis. The core dedupes by screen-name equality
        // (same name twice in a row = no boundary events), so the next line
        // confirms the boundary path was even reached on the C++ side.
        UniTrack.log("[UniTrack] setScreen → name=%@ (calls core ut_set_screen which fires screen_start/screen_view/screen_end)", name)
        forEachProvider { $0.setScreen(name) }
        // Snapshot previous screen + transition timestamp on the binding side
        // so the boundary fan-out below can build matching screen_exited /
        // screen_viewed payloads for providers. The C++ core does its own
        // boundary work inside ut_set_screen — these two paths are kept in
        // lockstep so portal queue + Snowplow collector see identical
        // transitions (same field shape, same wire names from portal config).
        let now = Date()
        var previous: String?
        var dwellMs: Int = 0
        shared.lastScreenLock.lock()
        previous = shared.lastScreen
        if previous == name { previous = nil } // dedupe like the core does
        if let prev = previous, !prev.isEmpty,
           let lastAt = shared.lastScreenAt {
            dwellMs = Int(now.timeIntervalSince(lastAt) * 1000.0)
        }
        shared.lastScreen   = name
        shared.lastScreenAt = now
        shared.lastScreenLock.unlock()

        guard let ctx = shared.context else { return }
        ut_set_screen(ctx, name)

        // Fan-out boundary events to providers. Match the field names the
        // core emits (screen / screen_name / dwell_ms / foreground_sec /
        // from / from_screen / previous_screen_name / is_exit_screen) so
        // Snowplow's schema-aligned consumers see one canonical payload
        // regardless of which path delivered the event.
        if shared.screenLifecycleEnabled, let prev = previous, !prev.isEmpty {
            let foregroundSec = (dwellMs + 500) / 1000
            let endPayload: [String: Any] = [
                "screen":          prev,
                "screen_name":     prev,
                "dwell_ms":        dwellMs,
                "foreground_sec":  foregroundSec,
                "is_exit_screen":  false,
            ]
            dispatchToProviders(shared.screenEndEventName, endPayload)
        }
        // screen_view (legacy back-compat) — kept so older portal consumers
        // and the Snowplow native ScreenView call (above via setScreen) stay
        // mutually consistent.
        let viewPayload: [String: Any] = [
            "screen":      name,
            "screen_name": name,
        ]
        dispatchToProviders("screen_view", viewPayload)
        if shared.screenLifecycleEnabled {
            var startPayload: [String: Any] = [
                "screen":      name,
                "screen_name": name,
            ]
            if let prev = previous, !prev.isEmpty {
                startPayload["from"]                 = prev
                startPayload["from_screen"]          = prev
                startPayload["previous_screen_name"] = prev
            }
            dispatchToProviders(shared.screenStartEventName, startPayload)
        }
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
        // Cache wire-event names for the screen-boundary fan-out done in
        // setScreen() so the Snowplow / Firebase providers see screen_viewed /
        // screen_exited under whatever taxonomy the portal set, matching what
        // the core fires into the HTTP queue. journeyCapture=false disables
        // both arms (core skips lifecycle events; binding skips fan-out).
        screenStartEventName = config.screenStartEvent ?? "screen_view"
        screenEndEventName   = config.screenEndEvent   ?? "screen_view"
        screenLifecycleEnabled = config.journeyCapture

        let cfgJson = UniTrack.buildConfigJson(config)
        context = ut_init(apiKey, cfgJson, UT_PLATFORM_IOS)
        guard context != nil else {
            NSLog("[UniTrack] ut_init failed")
            return
        }
        ut_set_log_level(context, ut_log_level(rawValue: UInt32(config.logLevel.rawValue)))

        // Seed the session-stat snapshot so AppLifecycleObserver + apps see
        // the right values immediately (vs racing the first background event).
        sessionStatLock.lock()
        sessionStartedAtSnapshot = Date()
        sessionTimeoutMsValue = config.sessionTimeoutMs
        sessionStatLock.unlock()

        // Attach device/app metadata to every event (model, OS, app version,
        // locale, …) — collected once here. Snapshot is kept on the shared
        // instance so providers (SnowplowProvider) can build their own
        // application_context entity from the same bag without re-running
        // the platform queries.
        let deviceJSON = DeviceInfo.json()
        ut_set_device_info(context, deviceJSON)
        cachedDeviceBag = Self.parseDeviceBag(deviceJSON)

        // Install the HTTP transport callback (uses URLSession).
        HTTPBridge.install(into: context!)

        if config.autoCapture {
            if config.trackScreens         { ViewControllerSwizzler.install() }
            // Auto-instrument every WKWebView: swizzle init to inject a
            // tracking JS + script message handler. Every web view (in-app
            // browser, third-party SDK shell) starts emitting click +
            // navigate events to UniTrack without per-call wiring.
            UniTrackWebView.install()
            if config.trackTaps            {
                ControlSwizzler.install()
                // Many screens use UITapGestureRecognizer on a plain UIView
                // instead of a UIControl (custom card, image, label). Those
                // never go through UIApplication.sendAction so ControlSwizzler
                // misses them. GestureRecognizerSwizzler closes the gap by
                // swizzling UIGestureRecognizer.setState — only tap recognizers
                // reaching .recognized fire a click event, so pan/pinch/swipe
                // recognizers stay silent.
                GestureRecognizerSwizzler.install()
            }
            if config.trackNetwork {
                UniTrackURLProtocol.install()
                // Don't capture the SDK's own uploads (avoids a feedback loop:
                // upload → captured as network_request → forwarded → captured…).
                if let ep = config.endpoint, let host = URL(string: ep)?.host {
                    UniTrackURLProtocol.excludeURL(containing: host)
                }
            }
            // Surface what we installed so a "trackTaps stays silent" bug
            // becomes obvious in the Xcode console (vs. silently no-op'ing
            // because the portal turned a flag off). Each swizzler is
            // idempotent so repeating this on hot-reload is safe.
            UniTrack.log("[UniTrack] auto-capture installed → screens=%@ taps=%@ network=%@",
                         config.trackScreens ? "ON" : "off",
                         config.trackTaps    ? "ON" : "off",
                         config.trackNetwork ? "ON" : "off")
            if config.trackMemoryWarnings  { MemoryWarningObserver.install() }
            AppLifecycleObserver.install()
        }

        // Cold-start metric
        let coldMs = Int(Date().timeIntervalSince(coldStartAt) * 1000)
        ut_log_app_start(context, coldMs)
        isInitialized = true

        // Bring up any providers registered before initialize().
        for p in providers { p.initializeProvider() }

        // Spin up the per-provider ack queue worker: polls every 2s, retries
        // with exponential backoff (1s → 5min cap, max 10 retries, 7-day TTL).
        UniTrack.startPendingWorker()

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
