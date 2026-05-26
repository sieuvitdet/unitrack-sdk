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

    private var tracker: TrackerController?

    public init(endpoint: String,
                appId: String,
                namespace: String = "UniTrack",
                userContext: [String: Any]? = nil,
                userContextSchema: String? = nil,
                schemas: [String: String] = [:],
                options: SnowplowOptions = SnowplowOptions()) {
        self.endpoint = endpoint
        self.appId = appId
        self.namespace = namespace
        self.userContext = userContext
        self.userContextSchema = userContextSchema
        self.schemas = schemas
        self.options = options
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
}
#else
// SnowplowTracker not linked — provide a stub so the file still compiles if the
// pod is present without its dependency (shouldn't happen in normal use).
public final class SnowplowProvider: AnalyticsProvider {
    public init(endpoint: String, appId: String, namespace: String = "UniTrack",
                userContext: [String: Any]? = nil, userContextSchema: String? = nil,
                schemas: [String: String] = [:]) {}
    public func initializeProvider() {
        NSLog("[UniTrackSnowplow] SnowplowTracker not available")
    }
    public func track(_ name: String, _ properties: [String: Any]) {}
    public func setUser(_ userId: String?, _ traits: [String: Any]) {}
    public func setScreen(_ name: String) {}
}
#endif
