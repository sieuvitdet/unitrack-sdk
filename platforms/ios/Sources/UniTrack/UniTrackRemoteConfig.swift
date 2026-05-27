// UniTrackRemoteConfig.swift
//
// Fetches the app's tracking config from the portal at startup, so endpoints,
// appId, schemas, provider settings, super-properties and the event registry can
// change WITHOUT rebuilding the app. The portal is the source of truth; this
// helper just downloads + caches it.
//
// Resilience (the app must never fail to launch because the portal is down):
//   • On success → cache to UserDefaults and return the fresh config.
//   • On failure/timeout → return the last cached config, or the supplied default.
//
// Usage (in AppDelegate, before configuring tracking):
//   UniTrackRemoteConfig.fetch(
//       apiKey: API_KEY,
//       configURL: "https://.../event-tracking-mobile/config",
//       timeout: 3
//   ) { config in
//       CameraAnalytics.start(remote: config)   // build UniTrack.Config + providers
//   }

import Foundation

public struct UniTrackRemoteConfig: Codable {
    public var version: Int
    public var endpoint: String
    public var sdkConfig: SDKConfig
    public var snowplow: SnowplowConfig
    public var firebase: FirebaseConfig
    public var eventRegistry: [EventDef]
    public var rules: [Rule]?

    // Phase 2 rewrite rule: match an auto-captured event → a business event.
    public struct Rule: Codable {
        public var matchEvent: String
        public var matchScreen: String?
        public var matchElementKey: String?
        public var toName: String
        public var addProps: [String: AnyCodable]?
        enum CodingKeys: String, CodingKey {
            case matchEvent = "match_event"
            case matchScreen = "match_screen"
            case matchElementKey = "match_element_key"
            case toName = "to_name"
            case addProps = "add_props"
        }
    }

    public struct SDKConfig: Codable {
        public var batchSize: Int?
        public var flushIntervalMs: Int?
        public var samplingRate: Double?
        public var autoCapture: Bool?
        public var trackScreens: Bool?
        public var trackTaps: Bool?
        public var trackNetwork: Bool?
        public var logLevel: String?
        public var journeyCapture: Bool?
        public var sessionTimeoutMs: Int?
    }

    public struct SnowplowConfig: Codable {
        public var enabled: Bool?
        public var endpoint: String?
        public var appId: String?
        public var namespace: String?
        public var userContext: [String: AnyCodable]?
        public var userContextSchema: String?
        public var options: [String: Bool]?
        public var schemas: [String: String]?
    }

    public struct FirebaseConfig: Codable {
        public var enabled: Bool?
        public var options: FBOptions?
        public var superProperties: [String: AnyCodable]?
        public var userProperties: [String: AnyCodable]?

        public struct FBOptions: Codable {
            public var apiKey: String?
            public var appId: String?            // GOOGLE_APP_ID
            public var projectId: String?
            public var gcmSenderId: String?      // GCM_SENDER_ID
            public var bundleId: String?
            public var storageBucket: String?
        }
    }

    public struct EventDef: Codable {
        public var name: String
        public var template: [String: String]?
        public var schema: String?
        public var forward: Bool?
    }

    // JSON keys are snake_case on the wire.
    enum CodingKeys: String, CodingKey {
        case version, endpoint, rules
        case sdkConfig = "sdk_config"
        case snowplow, firebase
        case eventRegistry = "event_registry"
    }

    /// Map decoded config rules → UniTrack.EventRule for the SDK.
    public func toEventRules() -> [UniTrack.EventRule] {
        (rules ?? []).map { r in
            UniTrack.EventRule(
                matchEvent: r.matchEvent,
                matchScreen: r.matchScreen,
                matchElementKey: r.matchElementKey,
                toName: r.toName,
                addProps: r.addProps?.unwrapped() ?? [:])
        }
    }

    // MARK: - Fetch + cache

    private static func cacheKey(_ apiKey: String) -> String { "unitrack.config.\(apiKey)" }

    /// Fetch config from the portal. Always calls `completion` exactly once with a
    /// usable config (fresh, cached, or `fallback`). Never blocks the main thread.
    public static func fetch(apiKey: String,
                             configURL: String,
                             timeout: TimeInterval = 3,
                             fallback: UniTrackRemoteConfig? = nil,
                             completion: @escaping (UniTrackRemoteConfig) -> Void) {
        let resolveFailure: () -> UniTrackRemoteConfig = {
            cached(apiKey: apiKey) ?? fallback ?? .builtinDefault()
        }
        guard let url = URL(string: configURL) else {
            completion(resolveFailure()); return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var result: UniTrackRemoteConfig
            if let data = data,
               let cfg = try? JSONDecoder().decode(UniTrackRemoteConfig.self, from: data) {
                result = cfg
                cache(cfg, apiKey: apiKey)
            } else {
                result = resolveFailure()
            }
            completion(result)
        }.resume()
    }

    public static func cached(apiKey: String) -> UniTrackRemoteConfig? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(apiKey)) else { return nil }
        return try? JSONDecoder().decode(UniTrackRemoteConfig.self, from: data)
    }

    private static func cache(_ cfg: UniTrackRemoteConfig, apiKey: String) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: cacheKey(apiKey))
        }
    }

    /// Minimal default when there is no cache and the portal is unreachable.
    public static func builtinDefault() -> UniTrackRemoteConfig {
        UniTrackRemoteConfig(
            version: 0,
            endpoint: "https://mobix.asia/event-tracking-mobile/v1/events",
            sdkConfig: SDKConfig(batchSize: 10, flushIntervalMs: 3000, samplingRate: 1.0,
                                 autoCapture: true, trackScreens: true, trackTaps: true,
                                 trackNetwork: true, logLevel: "warn"),
            snowplow: SnowplowConfig(enabled: false),
            firebase: FirebaseConfig(enabled: false),
            eventRegistry: [],
            rules: nil
        )
    }
}

/// A tiny type-erased Codable so userContext/superProperties can hold mixed JSON
/// values (string/number/bool) without a fixed schema.
public struct AnyCodable: Codable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else { value = "" }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let b as Bool:   try c.encode(b)
        case let i as Int:    try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        default:              try c.encode(String(describing: value))
        }
    }
}

public extension Dictionary where Key == String, Value == AnyCodable {
    /// Unwrap to a plain [String: Any] for passing to providers.
    func unwrapped() -> [String: Any] { mapValues { $0.value } }
}
