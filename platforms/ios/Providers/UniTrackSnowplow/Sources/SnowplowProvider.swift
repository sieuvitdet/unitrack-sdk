// SnowplowProvider — forwards every UniTrack event to a Snowplow collector.
//
//   UniTrack.addProvider(SnowplowProvider(
//       endpoint: "https://collector.example.com",
//       appId: "701",
//       userContext: ["username": "duc"],
//       userContextSchema: "iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0",
//       schemas: ["add_to_cart": "iglu:com.acme/add_to_cart/jsonschema/1-0-0"]))
//   UniTrack.initialize(apiKey: ...)
//
// Events with a matching `schemas` entry → self-describing events; others →
// Structured events (category "unitrack"). The optional user-context entity is
// attached to every event. Uses the Snowplow iOS tracker SDK (SnowplowTracker).

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

    private let endpoint: String
    private let appId: String
    private let namespace: String
    private var userContext: [String: Any]?
    private let userContextSchema: String?
    private let schemas: [String: String]
    private let options: SnowplowOptions
    /// Convention vendor + version for the tracking* helpers. The schema URI
    /// built per call is `iglu:<igluVendor>/<eventName>/jsonschema/<defaultVersion>`.
    /// Both come from the portal; helpers warn + no-op when either is missing.
    private let igluVendor: String?
    private let defaultVersion: String
    /// Convention kind → event name override map. Lets a third-party integrator
    /// re-use the SDK helpers under their own taxonomy (e.g. "fss_event_click")
    /// without forking. Helpers look up `eventNames[kind]` first, then fall
    /// back to the SDK default name baked into the helper.
    private var eventNames: [String: String]

    private var tracker: TrackerController?

    public init(endpoint: String,
                appId: String,
                namespace: String = "UniTrack",
                userContext: [String: Any]? = nil,
                userContextSchema: String? = nil,
                schemas: [String: String] = [:],
                options: SnowplowOptions = SnowplowOptions(),
                igluVendor: String? = nil,
                defaultVersion: String = "1-0-0",
                eventNames: [String: String] = [:]) {
        self.endpoint = endpoint
        self.appId = appId
        self.namespace = namespace
        self.userContext = userContext
        self.userContextSchema = userContextSchema
        self.schemas = schemas
        self.options = options
        self.igluVendor = igluVendor
        self.defaultVersion = defaultVersion
        self.eventNames = eventNames
    }

    /// Hot-reload the convention kind → event name map. Call this when the
    /// portal pushes a new remote config without re-creating the provider.
    public func setEventNames(_ map: [String: String]) {
        self.eventNames = map
    }

    /// Resolve a convention kind ("click", "result", …) to the actual event
    /// name. Portal-supplied value wins; otherwise the SDK default below.
    private func eventName(for kind: String, default fallback: String) -> String {
        if let s = eventNames[kind], !s.isEmpty { return s }
        return fallback
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
        let network = NetworkConfiguration(endpoint: endpoint, method: .post)
        // All flags come from the developer-supplied options (defaults match
        // Snowplow's recommended mobile setup).
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
        tracker = Snowplow.createTracker(namespace: namespace,
                                         network: network,
                                         configurations: [trackerConfig])
        NSLog("[UniTrackSnowplow] tracker ready (\(endpoint), appId=\(appId), lifecycle=\(options.lifecycleAutotracking))")
    }

    public func updateUserContext(_ ctx: [String: Any]) { userContext = ctx }

    private func entities() -> [SelfDescribingJson] {
        guard let userContext = userContext, let schema = userContextSchema else {
            return []
        }
        return [SelfDescribingJson(schema: schema, andData: userContext)]
    }

    public func track(_ name: String, _ properties: [String: Any]) {
        guard let tracker = tracker else { return }
        if let schema = schemas[name] {
            // Self-describing event for mapped names.
            let sd = SelfDescribing(schema: schema, payload: properties)
            _ = sd.entities(entities())
            tracker.track(sd)
        } else {
            // Structured event for everything else.
            let structured = Structured(category: "unitrack", action: name)
            structured.label =
                (properties["screen"] ?? properties["screen_name"]) as? String
            structured.property =
                (properties["element_key"] ?? properties["state"]) as? String
            _ = structured.entities(entities())
            tracker.track(structured)
        }
    }

    public func setUser(_ userId: String?, _ traits: [String: Any]) {
        tracker?.subject?.userId = userId
        if !traits.isEmpty, var ctx = userContext {
            traits.forEach { ctx[$0.key] = $0.value }
            userContext = ctx
        }
    }

    public func setScreen(_ name: String) {
        guard let tracker = tracker else { return }
        let sv = ScreenView(name: name)
        _ = sv.entities(entities())
        tracker.track(sv)
    }

    // ─── First-class helpers for Snowplow built-in events ───────────────────
    //
    // The plain track() above produces either a Structured event or, if the
    // event name has a schemas[] entry, a SelfDescribing one. These helpers
    // are for the 5 typed events the Snowplow tracker SDK already models —
    // surface them so app code doesn't fall back to passing strings + matching
    // iglu schemas by hand. Each helper:
    //   1. builds the SDK's native event object (Timing, Ecommerce, …),
    //   2. merges global entities (user_context) with any per-call contexts,
    //   3. tracks it.
    //
    // `extraContexts` lets the caller attach event-scoped contexts (campaign,
    // experiment, screen, …). When `skipGlobalContexts` is true the global
    // user_context is dropped — useful when the caller is overriding it with
    // an event-scoped one (e.g. "logged out user" override on a logout event).

    /// Build the final entity list for one event: global (user_context) unless
    /// suppressed, then per-call contexts. Keeps the assembly logic in one
    /// place so adding e.g. a session entity later only takes a single edit.
    private func buildEntities(_ extra: [SelfDescribingJson]?,
                               skipGlobalContexts: Bool) -> [SelfDescribingJson] {
        var list = skipGlobalContexts ? [] : entities()
        if let extra = extra, !extra.isEmpty { list.append(contentsOf: extra) }
        return list
    }

    /// `Timing` event — duration measurements (API latency, image load,
    /// animation, anything the team wants in a histogram).
    public func trackTiming(category: String,
                            variable: String,
                            timing: Int,
                            label: String? = nil,
                            extraContexts: [SelfDescribingJson]? = nil,
                            skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = Timing(category: category, variable: variable, timing: timing)
        ev.label = label
        _ = ev.entities(buildEntities(extraContexts, skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    /// `Ecommerce` legacy-shape transaction. v6 also ships an `EcommerceController`
    /// namespace with finer-grained actions (productView, addToCart, …) — for
    /// most apps the single-shot transaction is enough; expose finer ones if
    /// you ship a shop with multi-step funnels.
    public func trackEcommerceTransaction(orderId: String,
                                          totalValue: Double,
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
        // Snowplow's Objective-C bridge exposes these as NSNumber? — bridge Double explicitly.
        ev.taxValue    = taxValue.map { NSNumber(value: $0) }
        ev.shipping    = shipping.map { NSNumber(value: $0) }
        ev.city        = city
        ev.state       = state
        ev.country     = country
        ev.currency    = currency
        _ = ev.entities(buildEntities(extraContexts, skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    /// `MessageNotification` — push received / opened. `trigger` is the
    /// reason this notification fired (push, location, calendar, other).
    /// For category, body localization, attachments etc. set the optional
    /// properties on the returned event object via the closure if needed.
    public func trackMessageNotification(title: String,
                                         body: String,
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
        _ = ev.entities(buildEntities(extraContexts, skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    /// `DeepLinkReceived` — when the OS hands the app a URL (custom scheme or
    /// universal link). `referrer` is the previous URL when available.
    public func trackDeepLink(url: String,
                              referrer: String? = nil,
                              extraContexts: [SelfDescribingJson]? = nil,
                              skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = DeepLinkReceived(url: url)
        ev.referrer = referrer
        _ = ev.entities(buildEntities(extraContexts, skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    /// `ConsentGranted` — record a user grant on a privacy/consent document
    /// (GDPR / CCPA flows). `expiry` is ISO-8601 (e.g. "2026-12-31T00:00:00Z").
    public func trackConsentGranted(expiry: String,
                                    documentId: String,
                                    documentVersion: String,
                                    documentName: String? = nil,
                                    documentDescription: String? = nil,
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = ConsentGranted(expiry: expiry, documentId: documentId, version: documentVersion)
        ev.name = documentName
        ev.documentDescription = documentDescription
        _ = ev.entities(buildEntities(extraContexts, skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    /// `ConsentWithdrawn` — user revokes a previously granted consent. `all`
    /// withdraws every consent at once; pair document fields with all=false
    /// to withdraw just the specified document.
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
        _ = ev.entities(buildEntities(extraContexts, skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    /// Self-describing event with custom contexts. The 1-1 match for the
    /// JSON shape Snowplow's tp2 collector receives:
    ///   { event: { schema, data }, contexts: [ {schema,data}, … ] }
    /// `extraContexts` is added AFTER the global user_context unless
    /// `skipGlobalContexts: true` — same rule as the typed helpers above.
    public func trackSelfDescribing(schema: String,
                                    data: [String: Any],
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        let ev = SelfDescribing(schema: schema, payload: data)
        _ = ev.entities(buildEntities(extraContexts, skipGlobalContexts: skipGlobalContexts))
        tracker.track(ev)
    }

    // ─── Convention layer ──────────────────────────────────────────────────
    //
    // The 6 tracking* helpers below are what app code calls day-to-day. Each
    // hardcodes a convention event name ("event_click", "event_screen_view",
    // …); the iglu schema URI is built at call site from the portal config:
    //
    //     iglu:<igluVendor>/<event_name>/jsonschema/<defaultVersion>
    //
    // Bumping a schema major across the whole app = updating defaultVersion
    // on the portal; no app rebuild. Renaming the convention (or pointing
    // one helper at a different vendor) needs a code change here, on purpose
    // — these names are part of the SDK's public contract.
    //
    // The "Custom" helper at the bottom is the escape hatch for any new
    // event the team hasn't lifted into a typed helper yet.

    /// Build the convention schema URI. Returns nil + warns if the portal
    /// hasn't sent an iglu vendor — the helper bails rather than guess.
    private func schemaFor(eventName: String) -> String? {
        guard let vendor = igluVendor, !vendor.isEmpty else {
            NSLog("[UniTrackSnowplow] no iglu_vendor in portal config — \"\(eventName)\" dropped. Set snowplow.iglu_vendor in the portal Config tab.")
            return nil
        }
        return "iglu:\(vendor)/\(eventName)/jsonschema/\(defaultVersion)"
    }

    /// Convention event name for a button tap. Schema: `<vendor>/event_click`.
    /// `elementKey` is required (Snowplow funnels use it as the action handle);
    /// `label` is the human-readable text shown on the button.
    public func trackingClickEvent(elementKey: String,
                                   label: String? = nil,
                                   screen: String? = nil,
                                   data: [String: Any]? = nil,
                                   extraContexts: [SelfDescribingJson]? = nil,
                                   skipGlobalContexts: Bool = false) {
        guard let schema = schemaFor(eventName: eventName(for: "click", default: "event_click")) else { return }
        var payload: [String: Any] = ["element_key": elementKey]
        if let label  = label  { payload["label"]  = label }
        if let screen = screen { payload["screen"] = screen }
        if let data   = data   { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Convention event name for the outcome of a user action — success,
    /// failure, cancel. Schema: `<vendor>/event_result`. `status` is a free
    /// string ("success" | "fail" | "cancel" | …) so backend can group as
    /// the team needs without bumping the schema.
    public func trackingResultEvent(action: String,
                                    status: String,
                                    errorCode: String? = nil,
                                    errorMessage: String? = nil,
                                    durationMs: Int? = nil,
                                    data: [String: Any]? = nil,
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        guard let schema = schemaFor(eventName: eventName(for: "result", default: "event_result")) else { return }
        var payload: [String: Any] = ["action": action, "status": status]
        if let errorCode    = errorCode    { payload["error_code"]    = errorCode }
        if let errorMessage = errorMessage { payload["error_message"] = errorMessage }
        if let durationMs   = durationMs   { payload["duration_ms"]   = durationMs }
        if let data         = data         { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Convention event name for entering a screen. Goes through Snowplow's
    /// native `ScreenView` event (so SDK lifecycle/screen_context features
    /// keep working), then ALSO emits a SelfDescribing `event_screen_view`
    /// when the convention vendor is configured — gives backend both the
    /// Snowplow-standard shape and the team-convention shape from one call.
    public func trackingScreenView(screenName: String,
                                   fromScreen: String? = nil,
                                   data: [String: Any]? = nil,
                                   extraContexts: [SelfDescribingJson]? = nil,
                                   skipGlobalContexts: Bool = false) {
        guard let tracker = tracker else { return }
        // 1) Native ScreenView so Snowplow's screen context + sessionization
        //    keep tracking. Carries the global user_context only.
        let sv = ScreenView(name: screenName)
        _ = sv.entities(buildEntities(nil, skipGlobalContexts: skipGlobalContexts))
        tracker.track(sv)
        // 2) Convention self-describing event with the team's vendor/version.
        guard let schema = schemaFor(eventName: eventName(for: "screen_view", default: "event_screen_view")) else { return }
        var payload: [String: Any] = ["screen_name": screenName]
        if let fromScreen = fromScreen { payload["from_screen"] = fromScreen }
        if let data       = data       { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Convention event name for a crash report. Schema: `<vendor>/event_crash`.
    /// Use this from the app's uncaught-exception handler / NSException catch
    /// site; UniTrack core also auto-emits a generic `crash` event but this
    /// helper is for when the team has a custom crash schema with extra fields.
    public func trackingCrash(message: String,
                              stack: String? = nil,
                              fatal: Bool = true,
                              type: String? = nil,
                              data: [String: Any]? = nil,
                              extraContexts: [SelfDescribingJson]? = nil,
                              skipGlobalContexts: Bool = false) {
        guard let schema = schemaFor(eventName: eventName(for: "crash", default: "event_crash")) else { return }
        var payload: [String: Any] = ["message": message, "fatal": fatal]
        if let stack = stack { payload["stack"] = stack }
        if let type  = type  { payload["type"]  = type }
        if let data  = data  { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Convention event name for an HTTP request observation. Schema:
    /// `<vendor>/event_api`. UniTrack core auto-captures network via
    /// URLProtocol — call this helper only when wrapping a third-party
    /// network layer the SDK can't see (gRPC, websocket, custom transport).
    public func trackingAPI(url: String,
                            method: String,
                            status: Int,
                            durationMs: Int,
                            requestBytes: Int? = nil,
                            responseBytes: Int? = nil,
                            errorMessage: String? = nil,
                            data: [String: Any]? = nil,
                            extraContexts: [SelfDescribingJson]? = nil,
                            skipGlobalContexts: Bool = false) {
        guard let schema = schemaFor(eventName: eventName(for: "api", default: "event_api")) else { return }
        var payload: [String: Any] = [
            "url": url, "method": method, "status": status, "duration_ms": durationMs,
        ]
        if let requestBytes  = requestBytes  { payload["request_bytes"]  = requestBytes }
        if let responseBytes = responseBytes { payload["response_bytes"] = responseBytes }
        if let errorMessage  = errorMessage  { payload["error_message"]  = errorMessage }
        if let data          = data          { payload.merge(data) { _, new in new } }
        trackSelfDescribing(schema: schema, data: payload,
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }

    /// Escape hatch for any convention name not (yet) lifted into a typed
    /// helper. Builds the schema URI the same way the typed helpers do —
    /// app side only needs the convention name + data.
    public func trackingCustomEvent(_ eventName: String,
                                    data: [String: Any]? = nil,
                                    extraContexts: [SelfDescribingJson]? = nil,
                                    skipGlobalContexts: Bool = false) {
        guard let schema = schemaFor(eventName: eventName) else { return }
        trackSelfDescribing(schema: schema, data: data ?? [:],
                            extraContexts: extraContexts,
                            skipGlobalContexts: skipGlobalContexts)
    }
}
#else
// SnowplowTracker not linked — provide stubs (incl. the typed-event helpers)
// so app code still compiles. All calls are no-ops; messages go through NSLog.
public final class SnowplowProvider: AnalyticsProvider {
    public init(endpoint: String, appId: String, namespace: String = "UniTrack",
                userContext: [String: Any]? = nil, userContextSchema: String? = nil,
                schemas: [String: String] = [:],
                igluVendor: String? = nil,
                defaultVersion: String = "1-0-0",
                eventNames: [String: String] = [:]) {}
    public func setEventNames(_ map: [String: String]) {}
    public func initializeProvider() {
        NSLog("[UniTrackSnowplow] SnowplowTracker not available")
    }
    public func track(_ name: String, _ properties: [String: Any]) {}
    public func setUser(_ userId: String?, _ traits: [String: Any]) {}
    public func setScreen(_ name: String) {}
    // Typed-event stubs: signatures use Any for SDK types we can't import.
    public func trackTiming(category: String, variable: String, timing: Int,
                            label: String? = nil,
                            extraContexts: [Any]? = nil,
                            skipGlobalContexts: Bool = false) {}
    public func trackEcommerceTransaction(orderId: String, totalValue: Double,
                                          items: [Any],
                                          affiliation: String? = nil,
                                          taxValue: Double? = nil,
                                          shipping: Double? = nil,
                                          city: String? = nil,
                                          state: String? = nil,
                                          country: String? = nil,
                                          currency: String? = nil,
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
    public func trackConsentWithdrawn(all: Bool,
                                      extraContexts: [Any]? = nil,
                                      skipGlobalContexts: Bool = false) {}
    public func trackSelfDescribing(schema: String, data: [String: Any],
                                    extraContexts: [Any]? = nil,
                                    skipGlobalContexts: Bool = false) {}
    // Convention helpers — stubs match the real provider's signatures.
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
    public func trackingCustomEvent(_ eventName: String, data: [String: Any]? = nil,
                                    extraContexts: [Any]? = nil,
                                    skipGlobalContexts: Bool = false) {}
}
#endif
