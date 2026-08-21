// SnowplowProvider — forwards UniTrack events to a Snowplow collector via the
// "convention layer". App code calls one of the 6 tracking* helpers below;
// the SDK builds the iglu schema URI per call from portal config:
//
//   iglu:<igluVendor>/<eventName>/jsonschema/<defaultVersion>
//
// where eventName comes from `eventNames[kind]` (portal `event_names.<kind>`)
// or falls back to the SDK default name baked into the helper. Two context
// entities are auto-attached to every call:
//
//   user_context — data sourced from setUser(...) + the userContext bag.
//   core_action  — action_name (the resolved event name), timestamp (now),
//                  screen, element_key.
//
// Both entity schema URIs come from portal `entities.<name>`. Adding extra
// entity names to that map registers them, but the app must supply their
// data per-call via the helper's `extraContexts:` parameter — the SDK only
// builds user_context + core_action from app state on its own.
//
// The Structured + per-event-name `schemas[]` lookup paths from the previous
// "blueprint engine" iteration are gone; `track(name, props)` is the lone
// generic call left, and it now goes out as a self-describing event under
// the convention schema (eventName = `name` passed in).

import Foundation
import UniTrack
#if canImport(SnowplowTracker)
import SnowplowTracker

/// Snowplow TrackerConfiguration flags the developer can toggle. Defaults match
/// Snowplow's recommended mobile setup; pass a custom one to override any flag.
public struct SnowplowOptions {
    public var base64Encoding: Bool
    public var platformContext: Bool
    public var applicationContext: Bool
    public var sessionContext: Bool
    public var screenContext: Bool
    public var lifecycleAutotracking: Bool
    public var screenEngagementAutotracking: Bool
    /// Snowplow's own UIViewController-swizzling ScreenView autotracking.
    /// DEFAULT false: UniTrack already emits screen_view (via setScreen with a
    /// module-prefix-stripped class name), so leaving Snowplow's autotracking on
    /// double-counts every screen — once from UniTrack (e.g. "HomeVC") and once
    /// from Snowplow's own swizzler with the raw name (e.g. "MyApp.HomeVC").
    public var screenViewAutotracking: Bool
    public var exceptionAutotracking: Bool
    public var installAutotracking: Bool
    public var deepLinkContext: Bool
    public var userAnonymisation: Bool

    public init(base64Encoding: Bool = true,
                platformContext: Bool = true,
                applicationContext: Bool = true,
                sessionContext: Bool = true,
                screenContext: Bool = true,
                lifecycleAutotracking: Bool = true,
                screenEngagementAutotracking: Bool = true,
                screenViewAutotracking: Bool = false,
                exceptionAutotracking: Bool = true,
                installAutotracking: Bool = true,
                deepLinkContext: Bool = true,
                userAnonymisation: Bool = false) {
        self.base64Encoding = base64Encoding
        self.platformContext = platformContext
        self.applicationContext = applicationContext
        self.sessionContext = sessionContext
        self.screenContext = screenContext
        self.lifecycleAutotracking = lifecycleAutotracking
        self.screenEngagementAutotracking = screenEngagementAutotracking
        self.screenViewAutotracking = screenViewAutotracking
        self.exceptionAutotracking = exceptionAutotracking
        self.installAutotracking = installAutotracking
        self.deepLinkContext = deepLinkContext
        self.userAnonymisation = userAnonymisation
    }
}

public final class SnowplowProvider: AnalyticsProvider {

    /// Max age an event may sit in the offline store before it is dropped
    /// instead of sent. Snowplow's own default is 30 days; 72h is the window
    /// the data team treats as a genuine offline session rather than a stale
    /// replay. Applied via EmitterConfiguration in initializeProvider().
    /// Parity: SnowplowProvider.kt MAX_EVENT_STORE_AGE.
    static let maxEventStoreAge: TimeInterval = 72 * 60 * 60   // 72h

    // Business action names the data team pivots on, per their event spec.
    // These are deliberately constants, not portal-configurable: they name the
    // USER ACTION, while portal event_names[kind] names the SCHEMA. Conflating
    // the two is what shipped action_name="screen_view" to production.
    static let actionScreenViewed = "screen_viewed"   // screen appeared / came to foreground
    static let actionScreenExited = "screen_exited"   // user left the screen

    private let endpoint: String
    private let appId: String
    private let namespace: String
    private let options: SnowplowOptions
    /// Hybrid ScreenView mode. Khi true:
    ///   • setScreen(name) fire Snowplow builtin ScreenView(name:) →
    ///     event vendor `com.snowplowanalytics.mobile/screen_view/1-0-0`
    ///     (kèm entity `screen` + `client_session` Snowplow tự attach).
    ///   • track("screen_viewed", …) bị skip trong SnowplowProvider (đã
    ///     bắn ở setScreen ngay trước đó — nếu không skip sẽ dup 1 event
    ///     custom vendor).
    ///   • screen_exited + screen_load_completed vẫn chạy path SelfDescribing
    ///     custom vendor (giữ event_action + reason + foreground_sec …).
    /// Default false → behavior cũ (setScreen no-op, screen_viewed đi qua
    /// SelfDescribing custom vendor như hiện tại).
    private let hybridScreenView: Bool

    // Convention vendor + version. Schema URI for any event/entity not given
    // an explicit URI in entities[] is built as
    //   iglu:<igluVendor>/<name>/jsonschema/<defaultVersion>
    private let igluVendor: String?
    private let defaultVersion: String

    // Convention kind → event name. Portal `event_names.<kind>` wins; missing
    // keys fall back to the hardcoded default ("event_click", …).
    private var eventNames: [String: String]

    // Auto-attached context entity name → schema URI. The SDK knows how to
    // build data for "user_context" and "core_action" itself; any other name
    // registered here just gets its schema, and the app must pass the data
    // for it via the helper's `extraContexts:` parameter.
    private var entities: [String: String]

    // Raw event names to drop before hitting the collector. Set via portal
    // `snowplow.drop_events` — apps register the SDK-emitted lifecycle events
    // (app_foreground / app_background / …) here when the data team hasn't
    // published matching iglu schemas, so those events don't become bad rows.
    private var dropEvents: Set<String>

    // user_context bag. Mutated by setUser(_:_:) so traits land on the next
    // event without the integrator having to re-register the provider.
    private var userContext: [String: Any]

    private var tracker: TrackerController?

    public init(endpoint: String,
                appId: String,
                namespace: String = "UniTrack",
                userContext: [String: Any] = [:],
                options: SnowplowOptions = SnowplowOptions(),
                igluVendor: String? = nil,
                defaultVersion: String = "1-0-0",
                eventNames: [String: String] = [:],
                entities: [String: String] = [:],
                dropEvents: [String] = [],
                hybridScreenView: Bool = false) {
        self.endpoint = endpoint
        self.appId = appId
        self.namespace = namespace
        self.userContext = userContext
        self.options = options
        self.igluVendor = igluVendor
        self.defaultVersion = defaultVersion
        self.eventNames = eventNames
        self.entities = entities
        self.dropEvents = Set(dropEvents)
        self.hybridScreenView = hybridScreenView
    }

    public func initializeProvider() {
        guard !endpoint.isEmpty else {
            NSLog("[UniTrackSnowplow] empty endpoint — provider disabled")
            return
        }
        // Don't let UniTrack capture our own uploads to the collector.
        if let host = URL(string: endpoint)?.host {
            UniTrack.excludeFromNetworkCapture(urlContaining: host)
        }
        // Custom NetworkConnection that wraps the default one and logs each
        // outgoing POST body + response status. Without this the only
        // visibility into wire-level traffic is "Connection error: -" from
        // Snowplow's internal Logger, which we muted above.
        let netConn = UniTrackSnowplowNetworkConnection(endpoint: endpoint, method: .post)
        let network = NetworkConfiguration(networkConnection: netConn)
        let trackerConfig = TrackerConfiguration()
            .appId(appId)
            .base64Encoding(options.base64Encoding)
            .platformContext(options.platformContext)
            .applicationContext(options.applicationContext)
            .sessionContext(options.sessionContext)
            .screenContext(options.screenContext)
            .lifecycleAutotracking(options.lifecycleAutotracking)
            .screenViewAutotracking(options.screenViewAutotracking)
            .screenEngagementAutotracking(options.screenEngagementAutotracking)
            .exceptionAutotracking(options.exceptionAutotracking)
            .installAutotracking(options.installAutotracking)
            .deepLinkContext(options.deepLinkContext)
            .userAnonymisation(options.userAnonymisation)
            // Mute the Snowplow tracker's internal Logger so DEBUG builds
            // don't spam "Connection error: -" + every retry log line into
            // the Xcode console. Without this, the Snowplow Logger setter
            // auto-flips .off → .error whenever DEBUG is defined (see
            // snowplow Logger.swift), which becomes noise once the
            // integrator has confirmed the collector is reachable. Keep
            // UniTrack.log lines (which are gated by UniTrack.verboseLogging)
            // as the single source of console output.
            .logLevel(.off)

        // Plugin: hook every event the Snowplow tracker emits so the
        // integrator at least sees an Xcode log line per event (gated by
        // UniTrack.verboseLogging). Without this, autotracked events
        // (application_foreground/background, screen_end, install,
        // exception) fire inside the tracker queue silently.
        //
        // We deliberately DON'T mirror these auto-tracked Snowplow events
        // back through UniTrack.track. Reason: Snowplow native events use
        // vendor `com.snowplowanalytics.mobile` / `com.snowplowanalytics.snowplow`
        // with their own schema names (vd `screen_end`, `application_background`).
        // Mirroring them would land on the portal as those raw names instead
        // of the team's own convention names (vd `event_screen_view`,
        // `event_app_background`). Plus the business events team cares about
        // already go through SnowplowProvider.track() → portal sees them via
        // UniTrack core fan-out — the mirror was double-emission.
        //
        // Apps that NEED a specific Snowplow auto event mirrored should add
        // their own per-schema plugin via the SnowplowTracker SDK directly.
        // Plugin kept registered (empty body) so future team needs that want
        // a per-schema afterTrack hook can extend it without re-creating the
        // tracker. We deliberately don't log auto-tracked Snowplow internal
        // events (screen_end, application_background, install, …) because:
        //   • The "─── Snowplow Tracking ───" envelope already prints the
        //     business events the integrator owns.
        //   • Snowplow internals are noise the team doesn't act on.
        let plugin = PluginConfiguration(identifier: "UniTrackForwarder")
            .afterTrack { _ in
                // No-op. See comment above.
            }

        // Offline event store: drop anything older than 72h instead of the
        // Snowplow default 30 days.
        //
        // Why: events live in the tracker's SQLite store until a flush
        // succeeds, and removeOldEvents() only runs INSIDE flush() — an app
        // that isn't opened simply keeps them. Production data showed a
        // median device→collector lag of 8.8 days and a max of 25.4, all
        // legal under the 30-day default, which lands weeks-old rows in the
        // warehouse tagged with a fresh collector_tstamp. 72h keeps genuine
        // offline/airplane-mode sessions while making stale replays
        // impossible.
        //
        // maxEventStoreSize stays at the SDK default (1000 events).
        let emitterConfig = EmitterConfiguration()
            .maxEventStoreAge(Self.maxEventStoreAge)

        // screen_end is fired by Snowplow's own ScreenSummary state machine —
        // the SDK never calls it, so it cannot attach core_action the way
        // setScreen() does for ScreenView. A GlobalContext is Snowplow's
        // supported hook for exactly this: match the event by schema, generate
        // the entity. Without it screen_end reaches the warehouse with no
        // session_id and no action_name, and the data team cannot join it.
        //
        // Only registered in hybrid mode: with hybrid off the builtin screen
        // events are not part of the contract and stamping them would add
        // entities to events nobody consumes.
        var configurations: [ConfigurationProtocol] = [trackerConfig, emitterConfig, plugin]
        if hybridScreenView {
            // Resolve core_action's URI once, here, where the portal entities
            // map is in scope. Nil when the operator hasn't registered
            // core_action — the generator then emits nothing rather than
            // inventing a schema.
            Self.sharedCoreActionSchema = entities["core_action"].flatMap { normalizeEntityURI($0) }
            Self.sharedUserLock.lock()
            Self.sharedUserSchema = entities["user_context"].flatMap { normalizeEntityURI($0) }
            Self.sharedUserContext = userContext
            Self.sharedUserLock.unlock()
            configurations.append(
                GlobalContextsConfiguration().contextGenerators([
                    "unitrackScreenEnd": Self.makeScreenEndContext()
                ])
            )
        }

        tracker = Snowplow.createTracker(namespace: namespace,
                                         network: network,
                                         configurations: configurations)
        NSLog("[UniTrackSnowplow] tracker ready (\(endpoint), appId=\(appId), vendor=\(igluVendor ?? "—"), version=\(defaultVersion), entities=\(entities.keys.sorted().joined(separator: ",")), hybridScreenView=\(hybridScreenView))")
    }

    /// core_action generator for Snowplow's auto-fired `screen_end`.
    ///
    /// Mirrors the entity buildEntities() attaches to the ScreenView we fire
    /// ourselves, so both halves of a screen visit carry the same join keys:
    ///   action_name — "screen_exited" (the data team's business name)
    ///   session_id  — read live; screen_end fires as the screen closes, so
    ///                 "now" IS the event time, unlike a queued replay
    ///   screen      — lifted from the `screen` entity Snowplow attaches,
    ///                 because ScreenEnd's own payload is empty by design
    ///
    /// Static (no self capture): GlobalContext is retained by the tracker for
    /// its whole lifetime, and capturing the provider would form a cycle.
    private static func makeScreenEndContext() -> GlobalContext {
        GlobalContext(
            generator: { event in
                var data: [String: Any] = ["action_name": Self.actionScreenExited]

                let sid = UniTrack.currentSessionId()
                if !sid.isEmpty { data["session_id"] = sid }

                // ScreenEnd carries no payload of its own. Snowplow DOES attach
                // a `screen` entity, but not until after global-context
                // generators have run — reading event.entities here comes back
                // empty (verified on session 7785b4db: core_action.screen was
                // missing on all 76 builtin screen_end rows). Ask UniTrack
                // instead: screen_end fires for the screen being left, which is
                // exactly the last setScreen() UniTrack recorded.
                // Set by setScreen() immediately before the ScreenView that
                // triggers this screen_end. Falls back to previousScreenName()
                // only for a screen_end with no preceding setScreen (app
                // backgrounding), where lastScreen IS the outgoing screen.
                Self.exitingScreenLock.lock()
                let exiting = Self.exitingScreen
                Self.exitingScreenLock.unlock()
                if let name = exiting ?? UniTrack.previousScreenName(), !name.isEmpty {
                    data["screen"] = name
                }

                let now = ISO8601DateFormatter().string(from: Date())
                data["timestamp"]  = now
                data["start_time"] = now

                // Schema URI comes from the same portal entities map the
                // non-builtin path uses, so operators configure it in one place.
                guard let schema = Self.sharedCoreActionSchema else { return [] }

                // screen_end cũng cần user_context: Snowplow tự bắn event này
                // nên nó không đi qua trackSelfDescribingInternal, chỗ duy
                // nhất gắn entity user. Đo 2026-08-21: screen_end 0/24 (iOS)
                // và 0/53 (Android) có user_context — đội Data join theo user
                // mất sạch screen_end.
                var out: [SelfDescribingJson] = []
                Self.sharedUserLock.lock()
                let uSchema = Self.sharedUserSchema
                let uBag    = Self.sharedUserContext
                Self.sharedUserLock.unlock()
                if let uSchema = uSchema, !uBag.isEmpty {
                    out.append(SelfDescribingJson(schema: uSchema,
                                                  andData: Self.stringifyAll(uBag)))
                }
                out.append(SelfDescribingJson(schema: schema,
                                              andData: Self.stringifyAll(data)))
                return out
            },
            filter: { event in
                (event.schema ?? "").contains("/screen_end/jsonschema/")
            }
        )
    }

    /// core_action schema URI, captured at init so the static GlobalContext
    /// generator can reach it without retaining the provider.
    private static var sharedCoreActionSchema: String?

    /// user_context schema + bag cho generator screen_end. Khác Android
    /// (MutableMap = tham chiếu sống), `userContext` bên iOS là struct value
    /// type nên phải đồng bộ lại mỗi lần setUser, không thể giữ tham chiếu.
    private static var sharedUserSchema: String?
    private static var sharedUserContext: [String: Any] = [:]
    private static let sharedUserLock = NSLock()

    /// Screen the app is leaving, handed to the screen_end generator by
    /// setScreen(). Static + locked for the same reason as the schema above:
    /// the GlobalContext generator must not retain the provider.
    private static var exitingScreen: String?
    private static let exitingScreenLock = NSLock()

    /// Pull the short event name out of an iglu URI tail. Returns "" if the
    /// URI doesn't match the standard 4-part shape.
    /// `iglu:vendor/event_name/jsonschema/1-0-0` → `event_name`
    private static func extractEventName(fromSchema schema: String) -> String {
        let parts = schema.split(separator: "/")
        // ["iglu:vendor", "event_name", "jsonschema", "1-0-0"]
        guard parts.count >= 4 else { return "" }
        return String(parts[1])
    }

    // MARK: - Hot reloads from remote config

    public func updateUserContext(_ ctx: [String: Any]) { userContext = ctx }
    public func setEventNames(_ map: [String: String])  { eventNames = map }
    public func setEntities(_ map: [String: String])    { entities = map }
    public func setDropEvents(_ names: [String])        { dropEvents = Set(names) }

    /// Tear down the underlying Snowplow tracker so a re-init (vd portal
    /// pushed a new endpoint) doesn't leak the old tracker. Without this,
    /// the SnowplowTracker SDK keeps the tracker registered under its
    /// namespace and every event fans out to BOTH the old endpoint AND the
    /// new one. Host calls this on the old provider before adding the new
    /// one via UniTrack.addProvider(SnowplowProvider(...)).
    public func tearDown() {
        // Snowplow.remove(tracker:) unregisters the controller from the
        // SnowplowTracker SDK's internal namespace registry; without this
        // step a subsequent createTracker with the same namespace simply
        // returns a fresh controller while the old upload queue keeps
        // draining to the old endpoint.
        if let t = tracker { _ = Snowplow.remove(tracker: t) }
        tracker = nil
    }

    // MARK: - Provider protocol

    public func setUser(_ userId: String?, _ traits: [String: Any]) {
        tracker?.subject?.userId = userId
        if let userId = userId { userContext["user_id"] = userId }
        for (k, v) in traits { userContext[k] = v }
        // Đồng bộ sang bản static cho generator screen_end — userContext là
        // value type nên generator không tự thấy thay đổi. Logout gọi
        // setUser(nil, [:]) nhưng KHÔNG xoá bag, giữ đúng hành vi cũ của
        // đường track() thường.
        Self.sharedUserLock.lock()
        Self.sharedUserContext = userContext
        Self.sharedUserLock.unlock()
    }

    /// Generic catch-all that the UniTrack core fans events out to. Routed
    /// through the convention path:
    ///   1. Map raw event name → convention kind (vd "screen_viewed" → "screen_view")
    ///   2. Resolve kind → wire name via portal event_names[kind]
    ///      (vd "screen_view" → "event_screen_view" or whatever operator set)
    ///   3. Build schema URI from vendor + resolved name + version
    ///   4. Stamp event_action = raw name into data so consumers can tell
    ///      "screen_viewed" vs "screen_exited" under the same schema parent
    /// App code should prefer the typed tracking* helpers for type safety.
    public func track(_ name: String, _ properties: [String: Any]) {
        // Loop guard — events we mirrored from the Snowplow plugin back to
        // UniTrack carry `_skip_snowplow: true`. Tracking them again would
        // double-emit to the collector and loop infinitely.
        if (properties["_skip_snowplow"] as? Bool) == true { return }
        // Portal-configured blocklist — drop before URL build so events
        // without a published iglu schema (app_foreground, app_background, …)
        // don't turn into bad rows at the enricher.
        if dropEvents.contains(name) { return }
        // Hybrid mode: setScreen(name) đã fire builtin ScreenView cho
        // screen_viewed rồi. Nếu chạy tiếp path SelfDescribing custom vendor
        // dưới đây → dup (1 builtin + 1 custom). Skip.
        // screen_exited + screen_load_completed vẫn đi qua path này (giữ custom
        // vendor với event_action + reason + foreground_sec fields).
        // In hybrid mode the builtin Snowplow events are the contract:
        //   screen_viewed → com.snowplowanalytics.mobile/screen_view
        //   screen_exited → com.snowplowanalytics.mobile/screen_end
        // Both already carry core_action (session_id + the business
        // action_name), and screen_end additionally carries screen_summary
        // with foreground_sec/background_sec. Letting the custom-vendor copy
        // through as well double-counts every screen visit — measured 1:1 on
        // session 7785b4db (77 builtin screen_view vs 76 custom screen_end).
        //
        // screen_load_completed stays on the custom path on purpose: Snowplow
        // has no builtin equivalent and load_time_ms only UniTrack can measure.
        if hybridScreenView,
           name == "screen_viewed" || name == "screen_view" || name == "screen_exited" {
            return
        }
        // Auto-capture / screen-lifecycle events get routed to the right kind
        // so they all share 1 schema (vd: screen_viewed + screen_exited +
        // screen_load_completed → kind=screen_view → 1 iglu schema). When the
        // raw name isn't a known auto-capture event, the kind defaults to the
        // raw name itself (app-fired business events keep 1-to-1 mapping).
        let kind = Self.kindForRawEvent(name) ?? name
        let resolvedName = resolveEventName(kind: kind, defaultName: defaultEventNameFor(kind: kind, raw: name))
        guard let schema = schemaFor(eventName: resolvedName) else { return }
        // Stamp event_action so 3 events sharing the same schema parent stay
        // distinguishable downstream without parsing data fields.
        var enriched = properties
        if enriched["event_action"] == nil { enriched["event_action"] = name }
        // Stamp session_id directly into the event data — the only join key
        // shared with Portal + custom HTTP providers. Done at the property
        // level (not just core_action entity) so apps that haven't registered
        // core_action still ship it.
        let sid = UniTrack.currentSessionId()
        if enriched["session_id"] == nil && !sid.isEmpty { enriched["session_id"] = sid }
        trackSelfDescribing(schema: schema, eventName: resolvedName,
                            data: enriched, extraContexts: nil,
                            skipGlobalContexts: false)
    }

    /// Map raw event names emitted by core / auto-capture / app to a convention
    /// kind so they all share 1 iglu schema parent. Returns nil → caller uses
    /// the raw name as kind (app-fired custom business events).
    private static func kindForRawEvent(_ name: String) -> String? {
        switch name {
        // Click family
        case "click", "tap":
            return "click"
        // Screen family — split into 2 kinds so exit gets its own iglu schema:
        //   screen_view  ← entry + load-completed (share entry schema)
        //   screen_end   ← exit (separate schema; carries dwell_ms, foreground_sec, …)
        // Data team publishes iglu:<vendor>/screen_view + iglu:<vendor>/screen_end.
        case "screen_view", "screen_viewed", "screen_load_completed":
            return "screen_view"
        case "screen_exited":
            return "screen_end"
        // Network / API family
        case "network_request":
            return "api"
        // Crash family
        case "crash", "application_error":
            return "crash"
        // Session family
        case "session_started", "session_ended", "session_start", "session_end":
            return "session"
        default:
            return nil
        }
    }

    /// Default wire event name when portal didn't override.
    /// For unknown kinds (custom business events), the raw event name IS the
    /// default — so app code emitting `camera_pairing_completed` lands at
    /// `iglu:<vendor>/camera_pairing_completed/jsonschema/<ver>` unchanged.
    private func defaultEventNameFor(kind: String, raw: String) -> String {
        switch kind {
        case "click":       return "event_click"
        case "result":      return "event_result"
        case "screen_view": return "event_screen_view"
        case "screen_end":  return "screen_end"
        case "crash":       return "event_crash"
        case "api":         return "event_api"
        case "session":     return "event_session"
        default:            return raw   // custom business event keeps its name
        }
    }

    public func setScreen(_ name: String) { setScreen(name, previous: nil) }

    /// `previous` do UniTrack stamp (single source of truth). Khi nil thì để
    /// Snowplow tự suy như cũ — chỉ xảy ra nếu có caller gọi overload cũ.
    public func setScreen(_ name: String, previous: String?) {
        // Hybrid mode: fire Snowplow builtin ScreenView →
        //   iglu:com.snowplowanalytics.mobile/screen_view/1-0-0
        // Snowplow SDK tự attach entity `screen` (id, name, previousName, …)
        // + `client_session` — data team query builtin path, không cần custom
        // vendor cho screen_viewed nữa. screen_exited + screen_load_completed
        // vẫn giữ custom vendor (path track() dưới).
        //
        // Global entities (user_context, core_action, application_context)
        // vẫn attach — data team pivot theo action_name / user_id như cũ.
        if hybridScreenView, let tracker = tracker {
            let sv = ScreenView(name: name)
            // Stamp previousName từ UniTrack thay vì để Snowplow tự suy.
            // Snowplow giữ state screen riêng, không thấy screen_exited mà
            // UniTrack fire lúc app vào background → ở resume nó sẽ ghi
            // previousName = màn đứng trước lúc background, trong khi UniTrack
            // biết screen vào lại từ chính nó. Hai nguồn sự thật, một sai.
            if let previous = previous, !previous.isEmpty {
                _ = sv.previousName(previous)
            }
            // core_action.action_name is the BUSINESS action the data team
            // pivots on ("screen_viewed"), never the schema kind. Do NOT route
            // it through resolveEventName(): that reads eventNames[kind], a map
            // whose job is resolving the SCHEMA name, and FPT Life sets
            // event_names.screen_view = "screen_view" — which silently
            // overrode the default and shipped action_name="screen_view".
            _ = sv.entities(buildEntities(forEventName: "screen_view",
                                          screen: name, elementKey: nil,
                                          extra: nil,
                                          skipGlobalContexts: false,
                                          actionName: Self.actionScreenViewed))
            // Snowplow fires screen_end for the OUTGOING screen as a
            // side-effect of this track() call, and makeScreenEndContext()
            // runs inside it. Hand that generator the outgoing name here:
            // UniTrack.previousScreenName() has ALREADY been advanced to
            // `name` by setScreen() before this fan-out runs, so reading it
            // in the generator stamped core_action.screen with the screen
            // being ENTERED (measured: 52/53 rows wrong on iOS 482b48d9).
            Self.exitingScreenLock.lock()
            Self.exitingScreen = previous
            Self.exitingScreenLock.unlock()
            tracker.track(sv)
            UniTrack.log("[UniTrackSnowplow] hybrid setScreen → builtin ScreenView(name=%@) fired (com.snowplowanalytics.mobile/screen_view/1-0-0).", name)
            return
        }
        // Legacy path: no-op. Fire builtin ScreenView khi hybridScreenView=false
        // sẽ dup với screen_viewed đi qua track() → custom vendor. Giữ no-op
        // để AnalyticsProvider protocol compile.
        UniTrack.log("[UniTrackSnowplow] setScreen no-op — builtin ScreenView(\"%@\") SUPPRESSED. Convention event fires via track() path.", name)
    }

    // MARK: - Convention schema/entity plumbing

    /// Build the convention schema URI. Returns nil + warns when vendor missing.
    private func schemaFor(eventName: String) -> String? {
        guard let vendor = igluVendor, !vendor.isEmpty else {
            NSLog("[UniTrackSnowplow] no iglu_vendor in portal config — \"\(eventName)\" dropped. Set snowplow.iglu_vendor in the portal Config tab.")
            return nil
        }
        return "iglu:\(vendor)/\(eventName)/jsonschema/\(defaultVersion)"
    }

    /// Accept any of these inputs from portal entity config and return a
    /// well-formed iglu URI. Defensive — the portal UI guides the operator
    /// to enter a short name, but old configs may carry a full URI and a
    /// typo can drop the "iglu:" scheme; we fix both here.
    ///
    ///   "user_context"                                                  → iglu:<vendor>/user_context/jsonschema/<defaultVersion>
    ///   "vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0"            → iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0
    ///   "iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0"       → unchanged
    private func normalizeEntityURI(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("iglu:") { return s }
        // Any "/" → caller typed a path (likely missing the iglu: scheme).
        if s.contains("/") { return "iglu:" + s }
        // Short name path: build the full URI from vendor + version.
        guard let vendor = igluVendor, !vendor.isEmpty else { return nil }
        return "iglu:\(vendor)/\(s)/jsonschema/\(defaultVersion)"
    }

    /// Resolve a convention kind ("click", "result", …) to the actual event
    /// name. Portal-supplied value wins; otherwise the SDK default fallback.
    private func resolveEventName(kind: String, defaultName: String) -> String {
        if let s = eventNames[kind], !s.isEmpty { return s }
        return defaultName
    }

    /// Build the entity list attached to one event:
    ///   1. user_context        — from userContext bag (if entities["user_context"] set).
    ///   2. core_action         — from event meta (if entities["core_action"] set).
    ///   3. application_context — from UniTrack.applicationContext()
    ///                            (if entities["application_context"] set).
    ///   4. extraContexts       — anything the caller passed (campaign, experiment, …).
    /// Any other name in `entities` is registered but data-less — pass it via
    /// extraContexts when calling the helper. `skipGlobalContexts: true` drops
    /// the three built-ins (useful when the caller is overriding).
    /// - Parameter sessionId: the session id captured when the event was
    ///   CREATED. Pass it whenever the caller already has one so core_action
    ///   and the event payload cannot disagree; nil falls back to a live read.
    private func buildEntities(forEventName name: String,
                               screen: String?,
                               elementKey: String?,
                               extra: [SelfDescribingJson]?,
                               skipGlobalContexts: Bool,
                               actionName: String? = nil,
                               sessionId: String? = nil) -> [SelfDescribingJson] {
        var out: [SelfDescribingJson] = []
        if !skipGlobalContexts {
            if let userRaw = entities["user_context"],
               let userSchema = normalizeEntityURI(userRaw),
               !userContext.isEmpty {
                out.append(SelfDescribingJson(schema: userSchema,
                                              andData: Self.stringifyAll(userContext)))
            }
            if let coreRaw = entities["core_action"],
               let coreSchema = normalizeEntityURI(coreRaw) {
                let now = isoNow()
                // Prefer the raw event name (screen_viewed / screen_exited /
                // screen_load_completed) over the schema kind (screen_view)
                // so the data team can pivot on core_action.action_name
                // without cracking the event data payload.
                let resolvedActionName = actionName?.isEmpty == false ? actionName! : name
                var data: [String: Any] = [
                    "action_name": resolvedActionName,
                    "timestamp":   now,
                    // start_time mirrors the Iglu schema FPT Life consumes —
                    // the event was created on the client at this instant.
                    // Kept alongside the legacy `timestamp` field so existing
                    // downstream queries don't break.
                    "start_time":  now,
                ]
                if let screen = screen, !screen.isEmpty       { data["screen"]      = screen }
                if let key    = elementKey, !key.isEmpty      { data["element_key"] = key }
                // Đánh dấu event sinh ra bởi process KHÔNG có UI (VoIP push
                // của cuộc gọi đến, background fetch): user không hề mở app.
                // Những event này vẫn stamp session_id của phiên dùng thật gần
                // nhất — không mở session mới, không kéo dài session cũ (core:
                // headless_process_). Trộn chung khi thống kê thì session
                // trông như kéo dài hàng giờ.
                //
                // Đội Data lọc is_headless=false để đếm phiên sử dụng thật.
                // String để parity Iglu schema. Parity: Android
                // SnowplowProvider.kt.
                data["is_headless"] = UniTrack.isHeadlessLaunch() ? "true" : "false"
                // Stamp session_id onto every event — the single join key
                // shared with Portal + custom HTTP providers.
                //
                // ponytail: prefer the id the CALLER already captured when the
                // event was created. UniTrack.currentSessionId() lazily rotates
                // (session_manager.cpp:176 — past the 30' idle window it mints a
                // fresh UUID as a side effect), so calling it again down here
                // could stamp a DIFFERENT session than the one on the event
                // payload. Only fall back to a live read when the caller had
                // nothing to give us.
                let sid = sessionId ?? UniTrack.currentSessionId()
                if !sid.isEmpty { data["session_id"] = sid }
                out.append(SelfDescribingJson(schema: coreSchema,
                                              andData: Self.stringifyAll(data)))
            }
            // application_context — built from the device/app bag UniTrack
            // already collected at init (DeviceInfo). The SDK fills the
            // common fields; the integrator only registers the schema in the
            // portal entities map.
            if let appRaw = entities["application_context"],
               let appSchema = normalizeEntityURI(appRaw) {
                let bag = UniTrack.applicationContext()
                if !bag.isEmpty {
                    out.append(SelfDescribingJson(schema: appSchema,
                                                  andData: Self.stringifyAll(bag)))
                }
            }
        }
        if let extra = extra { out.append(contentsOf: extra) }
        return out
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    /// Cast every leaf value in a payload to String so downstream Iglu
    /// schemas that declare all fields as string don't reject the event
    /// into bad-events ("boolean/number found, string expected"). Rules:
    ///   • String → unchanged
    ///   • Bool   → "true" / "false"
    ///   • Number (Int/Int64/Double/NSNumber) → decimal string
    ///   • Dict   → recurse, then JSON-serialize to a single string leaf
    ///   • Array  → recurse, then JSON-serialize to a single string leaf
    ///   • nil / NSNull → "" (keep key, avoid missing-field surprises)
    ///   • Anything else → String(describing:)
    /// Called at the last mile before handing data to Snowplow so callers
    /// (auto-capture, swizzlers, helpers, host app) don't have to remember.
    private static func stringifyAll(_ dict: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in dict { out[k] = stringifyValue(v) }
        return out
    }

    private static func stringifyValue(_ v: Any) -> String {
        if v is NSNull { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            // NSNumber wraps Bool too; check via ObjCType so Bool serialize
            // to "true"/"false", not "1"/"0".
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let d = v as? [String: Any] {
            let inner = stringifyAll(d)
            if JSONSerialization.isValidJSONObject(inner),
               let data = try? JSONSerialization.data(withJSONObject: inner),
               let s = String(data: data, encoding: .utf8) { return s }
            return String(describing: inner)
        }
        if let a = v as? [Any] {
            let inner = a.map { stringifyValue($0) }
            if let data = try? JSONSerialization.data(withJSONObject: inner),
               let s = String(data: data, encoding: .utf8) { return s }
            return String(describing: inner)
        }
        return String(describing: v)
    }

    /// Internal: fire one self-describing event under `schema` with the
    /// configured auto-entities + caller's extras. Logs the envelope so the
    /// integrator can verify shape during development.
    private func trackSelfDescribing(schema: String,
                                     eventName: String,
                                     data: [String: Any],
                                     extraContexts: [SelfDescribingJson]?,
                                     skipGlobalContexts: Bool) {
        guard let tracker = tracker else {
            NSLog("[UniTrackSnowplow] SKIP \"\(eventName)\" — tracker not initialized")
            return
        }
        let filtered = data.filter { !$0.key.hasPrefix("_") }
        let screen     = (filtered["screen"]      ?? filtered["screen_name"]) as? String
        let elementKey = (filtered["element_key"] ?? filtered["element"])     as? String
        // `event_action` được stamp trong track() với raw name (screen_viewed,
        // screen_exited, ...) — dùng nó cho core_action.action_name để phân
        // biệt được các lifecycle event share cùng schema.
        let rawActionName = filtered["event_action"] as? String
        // Reuse the session id already stamped into the payload by track() so
        // core_action.session_id and the event body can never disagree. Both
        // used to call UniTrack.currentSessionId() independently, and that
        // accessor rotates on a 30' idle gap — two reads straddling the
        // boundary produced two different ids for one event.
        let stampedSessionId = filtered["session_id"] as? String
        let ctxs = buildEntities(forEventName: eventName,
                                 screen: screen, elementKey: elementKey,
                                 extra: extraContexts,
                                 skipGlobalContexts: skipGlobalContexts,
                                 actionName: rawActionName,
                                 sessionId: stampedSessionId)
        // Stringify at the boundary so ALL Iglu schemas that declare fields
        // as string stop rejecting events into bad-events, no matter what
        // type upstream (swizzlers, auto-capture, host helpers) passed in.
        let cleaned = Self.stringifyAll(filtered)
        let ev = SelfDescribing(schema: schema, payload: cleaned)
        _ = ev.entities(ctxs)
        tracker.track(ev)
        Self.logTracking(endpoint: endpoint, eventName: eventName,
                         schema: schema, data: cleaned, contexts: ctxs)
    }

    // MARK: - Snowplow built-in event helpers
    // Five typed events Snowplow's tracker SDK already models. Each attaches
    // the same global entities as the convention helpers via buildEntities().

    public func trackTiming(category: String, variable: String, timing: Int,
                            label: String? = nil,
                            extraContexts: [SelfDescribingJson]? = nil,
                            skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = Timing(category: category, variable: variable, timing: timing)
        ev.label = label
        _ = ev.entities(buildEntities(forEventName: "timing", screen: nil,
                                      elementKey: nil, extra: extraContexts,
                                      skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    public func trackEcommerceTransaction(orderId: String, totalValue: Double,
                                          items: [EcommerceItem],
                                          affiliation: String? = nil,
                                          taxValue: Double? = nil,
                                          shipping: Double? = nil,
                                          city: String? = nil,
                                          state: String? = nil,
                                          country: String? = nil,
                                          currency: String? = nil,
                                          extraContexts: [SelfDescribingJson]? = nil,
                                          skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = Ecommerce(orderId: orderId, totalValue: totalValue, items: items)
        ev.affiliation = affiliation
        ev.taxValue    = taxValue.map { NSNumber(value: $0) }
        ev.shipping    = shipping.map { NSNumber(value: $0) }
        ev.city        = city
        ev.state       = state
        ev.country     = country
        ev.currency    = currency
        _ = ev.entities(buildEntities(forEventName: "ecommerce_transaction",
                                      screen: nil, elementKey: nil,
                                      extra: extraContexts,
                                      skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    public func trackMessageNotification(title: String, body: String,
                                         trigger: MessageNotificationTrigger = .push,
                                         notificationTimestamp: String? = nil,
                                         category: String? = nil,
                                         action: String? = nil,
                                         sound: String? = nil,
                                         extraContexts: [SelfDescribingJson]? = nil,
                                         skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = MessageNotification(title: title, body: body, trigger: trigger)
        ev.notificationTimestamp = notificationTimestamp
        ev.category = category
        ev.action   = action
        ev.sound    = sound
        _ = ev.entities(buildEntities(forEventName: "message_notification",
                                      screen: nil, elementKey: nil,
                                      extra: extraContexts,
                                      skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    public func trackDeepLink(url: String, referrer: String? = nil,
                              extraContexts: [SelfDescribingJson]? = nil,
                              skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = DeepLinkReceived(url: url)
        ev.referrer = referrer
        _ = ev.entities(buildEntities(forEventName: "deep_link_received",
                                      screen: nil, elementKey: nil,
                                      extra: extraContexts,
                                      skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    public func trackConsentGranted(expiry: String, documentId: String,
                                    documentVersion: String,
                                    documentName: String? = nil,
                                    documentDescription: String? = nil,
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = ConsentGranted(expiry: expiry, documentId: documentId, version: documentVersion)
        ev.name = documentName
        ev.documentDescription = documentDescription
        _ = ev.entities(buildEntities(forEventName: "consent_granted",
                                      screen: nil, elementKey: nil,
                                      extra: extraContexts,
                                      skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    public func trackConsentWithdrawn(all: Bool,
                                      documentId: String? = nil,
                                      documentVersion: String? = nil,
                                      documentName: String? = nil,
                                      documentDescription: String? = nil,
                                      extraContexts: [SelfDescribingJson]? = nil,
                                      skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = ConsentWithdrawn()
        ev.all = all
        ev.documentId = documentId
        ev.version    = documentVersion
        ev.name       = documentName
        ev.documentDescription = documentDescription
        _ = ev.entities(buildEntities(forEventName: "consent_withdrawn",
                                      screen: nil, elementKey: nil,
                                      extra: extraContexts,
                                      skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    /// Self-describing event with caller-provided schema. Skips the convention
    /// schema builder; auto-entities still attach unless skipGlobalContexts.
    public func trackSelfDescribing(schema: String, data: [String: Any],
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        // Route through the internal helper so the log envelope is uniform.
        let nameHint = (data["action_name"] ?? data["event_name"]) as? String ?? "self_describing"
        trackSelfDescribing(schema: schema, eventName: nameHint, data: data,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    // MARK: - Convention helpers (app-facing)

    public func trackingClickEvent(elementKey: String, label: String? = nil,
                                   screen: String? = nil, data: [String: Any]? = nil,
                                   extraContexts: [SelfDescribingJson]? = nil,
                                   skipGlobalContexts: Bool = false) {
        let name = resolveEventName(kind: "click", defaultName: "event_click")
        guard let schema = schemaFor(eventName: name) else { return }
        var payload: [String: Any] = ["element_key": elementKey]
        if let label  = label  { payload["label"]  = label }
        if let screen = screen { payload["screen"] = screen }
        if let data   = data   { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, eventName: name, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    public func trackingResultEvent(action: String, status: String,
                                    errorCode: String? = nil, errorMessage: String? = nil,
                                    durationMs: Int? = nil, data: [String: Any]? = nil,
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        let name = resolveEventName(kind: "result", defaultName: "event_result")
        guard let schema = schemaFor(eventName: name) else { return }
        var payload: [String: Any] = ["action": action, "status": status]
        if let errorCode    = errorCode    { payload["error_code"]    = errorCode }
        if let errorMessage = errorMessage { payload["error_message"] = errorMessage }
        if let durationMs   = durationMs   { payload["duration_ms"]   = durationMs }
        if let data         = data         { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, eventName: name, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Convention event for entering a screen. Emits BOTH the Snowplow native
    /// ScreenView (sessionization, screen context) AND a SelfDescribing
    /// `event_screen_view` against the team vendor — one call, two payloads.
    public func trackingScreenView(screenName: String, fromScreen: String? = nil,
                                   data: [String: Any]? = nil,
                                   extraContexts: [SelfDescribingJson]? = nil,
                                   skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let sv = ScreenView(name: screenName)
        // Prefer the app-configured raw name (screen_viewed / …) so
        // core_action.action_name matches what trackSelfDescribing stamps —
        // otherwise this native ScreenView path fires with action_name="screen_view".
        let rawScreenName = resolveEventName(kind: "screen_view", defaultName: "screen_view")
        _ = sv.entities(buildEntities(forEventName: "screen_view",
                                      screen: screenName, elementKey: nil,
                                      extra: nil,
                                      skipGlobalContexts: skipGlobalContexts,
                                      actionName: rawScreenName))
        tracker.track(sv)
        let name = resolveEventName(kind: "screen_view", defaultName: "event_screen_view")
        guard let schema = schemaFor(eventName: name) else { return }
        var payload: [String: Any] = ["screen_name": screenName, "screen": screenName]
        if let fromScreen = fromScreen { payload["from_screen"] = fromScreen }
        if let data       = data       { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, eventName: name, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    public func trackingCrash(message: String, stack: String? = nil,
                              fatal: Bool = true, type: String? = nil,
                              data: [String: Any]? = nil,
                              extraContexts: [SelfDescribingJson]? = nil,
                              skipGlobalContexts: Bool = false) {
        let name = resolveEventName(kind: "crash", defaultName: "event_crash")
        guard let schema = schemaFor(eventName: name) else { return }
        var payload: [String: Any] = ["message": message, "fatal": fatal]
        if let stack = stack { payload["stack"] = stack }
        if let type  = type  { payload["type"]  = type }
        if let data  = data  { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, eventName: name, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    public func trackingAPI(url: String, method: String, status: Int, durationMs: Int,
                            requestBytes: Int? = nil, responseBytes: Int? = nil,
                            errorMessage: String? = nil, data: [String: Any]? = nil,
                            extraContexts: [SelfDescribingJson]? = nil,
                            skipGlobalContexts: Bool = false) {
        let name = resolveEventName(kind: "api", defaultName: "event_api")
        guard let schema = schemaFor(eventName: name) else { return }
        var payload: [String: Any] = [
            "url": url, "method": method, "status": status, "duration_ms": durationMs,
        ]
        if let requestBytes  = requestBytes  { payload["request_bytes"]  = requestBytes }
        if let responseBytes = responseBytes { payload["response_bytes"] = responseBytes }
        if let errorMessage  = errorMessage  { payload["error_message"]  = errorMessage }
        if let data          = data          { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, eventName: name, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Session-lifecycle convention — kind=`session`. Use for session_started
    /// / session_ended / any state-of-session event. Action is the lifecycle
    /// verb (started / ended / resumed); reason is what triggered the
    /// transition (cold_start / backgrounded / timeout / explicit_logout).
    public func trackingSession(action: String, reason: String? = nil,
                                durationMs: Int? = nil, source: String? = nil,
                                data: [String: Any]? = nil,
                                extraContexts: [SelfDescribingJson]? = nil,
                                skipGlobalContexts: Bool = false) {
        let name = resolveEventName(kind: "session", defaultName: "event_session")
        guard let schema = schemaFor(eventName: name) else { return }
        var payload: [String: Any] = ["action": action]
        if let reason     = reason     { payload["reason"]      = reason }
        if let durationMs = durationMs { payload["duration_ms"] = durationMs }
        if let source     = source     { payload["source"]      = source }
        if let data       = data       { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, eventName: name, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Escape hatch — for one-off events not (yet) lifted into a typed helper.
    /// Schema is built the same way: iglu:<vendor>/<eventName>/jsonschema/<version>.
    public func trackingCustomEvent(_ eventName: String, data: [String: Any]? = nil,
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        guard let schema = schemaFor(eventName: eventName) else { return }
        trackSelfDescribing(schema: schema, eventName: eventName,
                            data: data ?? [:],
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    // MARK: - Pretty log envelope (verbose only)

    private static func logTracking(endpoint: String, eventName: String,
                                    schema: String, data: [String: Any],
                                    contexts: [SelfDescribingJson]) {
        guard UniTrack.verboseLogging else { return }
        let ctxsArr: [[String: Any]] = contexts.map { ["schema": $0.schema, "data": $0.data] }
        let envelope: [String: Any] = [
            "endpoint": endpoint,
            "method":   "trackSelfDescribingEvent",
            "event":    ["schema": schema, "data": data],
            "contexts": ctxsArr,
        ]
        // Screen family gets its own tag so filtering by "SCREEN-VIEW" in
        // Xcode console isolates the exact events the data team asks about
        // (screen_viewed / screen_exited / screen_load_completed all go
        // through the same schema "screen_view").
        let isScreen = schema.contains("/screen_view/")
                       || eventName == "screen_view"
                       || (data["event_action"] as? String)?.hasPrefix("screen_") == true
        let tag = isScreen ? "SCREEN-VIEW" : "Snowplow Tracking"
        UniTrack.log("\n─── %@ ───  (convention event=\"%@\")\n%@",
                     tag, eventName, prettyJSON(envelope))
    }

    private static func prettyJSON(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "<unserializable>"
    }
}
#else
// Fallback when the SnowplowTracker pod is missing from the integrator's
// Podfile (rare — CocoaPods normally auto-pulls it via our podspec). All
// methods are no-ops + initializeProvider() logs a one-line warning, so the
// app still compiles + boots; tracking just silently doesn't reach Snowplow.
public final class SnowplowProvider: AnalyticsProvider {
    public init(endpoint: String, appId: String, namespace: String = "UniTrack",
                userContext: [String: Any] = [:],
                options: SnowplowOptions = SnowplowOptions(),
                igluVendor: String? = nil,
                defaultVersion: String = "1-0-0",
                eventNames: [String: String] = [:],
                entities: [String: String] = [:],
                dropEvents: [String] = []) {}
    public func initializeProvider() {
        NSLog("[UniTrackSnowplow] SnowplowTracker not available")
    }
    public func updateUserContext(_ ctx: [String: Any]) {}
    public func setEventNames(_ map: [String: String]) {}
    public func setEntities(_ map: [String: String]) {}
    public func setDropEvents(_ names: [String]) {}
    public func track(_ name: String, _ properties: [String: Any]) {}
    public func setUser(_ userId: String?, _ traits: [String: Any]) {}
    public func setScreen(_ name: String) {}
    public func trackTiming(category: String, variable: String, timing: Int,
                            label: String? = nil, extraContexts: [Any]? = nil,
                            skipGlobalContexts: Bool = false) {}
    public func trackEcommerceTransaction(orderId: String, totalValue: Double,
                                          items: [Any], affiliation: String? = nil,
                                          taxValue: Double? = nil, shipping: Double? = nil,
                                          city: String? = nil, state: String? = nil,
                                          country: String? = nil, currency: String? = nil,
                                          extraContexts: [Any]? = nil,
                                          skipGlobalContexts: Bool = false) {}
    public func trackMessageNotification(title: String, body: String,
                                         extraContexts: [Any]? = nil,
                                         skipGlobalContexts: Bool = false) {}
    public func trackDeepLink(url: String, referrer: String? = nil,
                              extraContexts: [Any]? = nil,
                              skipGlobalContexts: Bool = false) {}
    public func trackConsentGranted(expiry: String, documentId: String,
                                    documentVersion: String,
                                    extraContexts: [Any]? = nil,
                                    skipGlobalContexts: Bool = false) {}
    public func trackConsentWithdrawn(all: Bool, extraContexts: [Any]? = nil,
                                      skipGlobalContexts: Bool = false) {}
    public func trackSelfDescribing(schema: String, data: [String: Any],
                                    extraContexts: [Any]? = nil,
                                    skipGlobalContexts: Bool = false) {}
    public func trackingClickEvent(elementKey: String, label: String? = nil,
                                   screen: String? = nil, data: [String: Any]? = nil,
                                   extraContexts: [Any]? = nil,
                                   skipGlobalContexts: Bool = false) {}
    public func trackingResultEvent(action: String, status: String,
                                    errorCode: String? = nil, errorMessage: String? = nil,
                                    durationMs: Int? = nil, data: [String: Any]? = nil,
                                    extraContexts: [Any]? = nil,
                                    skipGlobalContexts: Bool = false) {}
    public func trackingScreenView(screenName: String, fromScreen: String? = nil,
                                   data: [String: Any]? = nil,
                                   extraContexts: [Any]? = nil,
                                   skipGlobalContexts: Bool = false) {}
    public func trackingCrash(message: String, stack: String? = nil,
                              fatal: Bool = true, type: String? = nil,
                              data: [String: Any]? = nil,
                              extraContexts: [Any]? = nil,
                              skipGlobalContexts: Bool = false) {}
    public func trackingAPI(url: String, method: String, status: Int, durationMs: Int,
                            requestBytes: Int? = nil, responseBytes: Int? = nil,
                            errorMessage: String? = nil, data: [String: Any]? = nil,
                            extraContexts: [Any]? = nil,
                            skipGlobalContexts: Bool = false) {}
    public func trackingSession(action: String, reason: String? = nil,
                                durationMs: Int? = nil, source: String? = nil,
                                data: [String: Any]? = nil,
                                extraContexts: [Any]? = nil,
                                skipGlobalContexts: Bool = false) {}
    public func trackingCustomEvent(_ eventName: String, data: [String: Any]? = nil,
                                    extraContexts: [Any]? = nil,
                                    skipGlobalContexts: Bool = false) {}
}
#endif
