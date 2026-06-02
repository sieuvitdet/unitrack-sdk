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
    /// W3C distributed-tracing settings (optional — absent = disabled).
    public var tracing: TracingConfig?

    // Phase 2 rewrite rule: match an auto-captured event → a business event.
    public struct Rule: Codable {
        public var matchEvent: String
        public var matchScreen: String?
        public var matchElementKey: String?
        public var matchClassName: String?
        public var toName: String
        public var addProps: [String: AnyCodable]?
        enum CodingKeys: String, CodingKey {
            case matchEvent = "match_event"
            case matchScreen = "match_screen"
            case matchElementKey = "match_element_key"
            case matchClassName = "match_class_name"
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
        /// Wire-taxonomy overrides — empty = SDK keeps default name.
        public var screenStartEvent: String?
        public var screenEndEvent:   String?
        public var screenLoadEvent:  String?
        enum CodingKeys: String, CodingKey {
            case batchSize, flushIntervalMs, samplingRate
            case autoCapture, trackScreens, trackTaps, trackNetwork
            case logLevel, journeyCapture, sessionTimeoutMs
            case screenStartEvent = "screen_start_event"
            case screenEndEvent   = "screen_end_event"
            case screenLoadEvent  = "screen_load_event"
        }
    }

    /// Per-platform { endpoint, appId } override (mirror of SwiftPackage).
    public struct SnowplowPlatformOverride: Codable {
        public var endpoint: String?
        public var appId: String?
    }

    public struct SnowplowConfig: Codable {
        public var enabled: Bool?
        public var endpoint: String?
        public var appId: String?
        public var namespace: String?
        public var userContext: [String: AnyCodable]?
        public var options: [String: Bool]?
        public var ios:     SnowplowPlatformOverride?
        public var android: SnowplowPlatformOverride?

        public var resolvedEndpoint: String? {
            #if os(iOS)
            if let v = ios?.endpoint, !v.isEmpty { return v }
            #endif
            return endpoint
        }
        public var resolvedAppId: String? {
            #if os(iOS)
            if let v = ios?.appId, !v.isEmpty { return v }
            #endif
            return appId
        }
        /// Convention vendor + version for the tracking* helpers — the helper
        /// builds `iglu:<igluVendor>/<event_name>/jsonschema/<defaultVersion>`
        /// at call site. App ships only the convention name; bumping a schema
        /// across all events = updating this on the portal, no app rebuild.
        /// Portal wire key is snake_case (`iglu_vendor`, `default_version`);
        /// other fields stay camelCase to match the existing portal payload.
        public var igluVendor: String?
        public var defaultVersion: String?
        /// Override map for the convention event names (kind → name).
        public var eventNames: [String: String]?
        /// Auto-attached context entities: entity name → iglu schema URI.
        public var entities: [String: String]?
        enum CodingKeys: String, CodingKey {
            case enabled, endpoint, appId, namespace, options
            case userContext
            case ios, android
            case igluVendor     = "iglu_vendor"
            case defaultVersion = "default_version"
            case eventNames     = "event_names"
            case entities
        }
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

    /// W3C trace-context propagation. When `enabled` and a request's host is
    /// in `allowlistHosts` (or the list is empty = match everything inside our
    /// own backends — see UniTrack.shouldInjectTraceHeader), the SDK injects
    /// the W3C `traceparent` header on outbound HTTP calls so backend logs can
    /// be joined with mobile logs by trace_id.
    ///
    /// Important: `allowlistHosts` is what stops us from leaking `traceparent`
    /// to third parties (Firebase, Maps, CDNs). Default empty here = "no host
    /// allowed"; the SDK only injects when the app or remote config supplies
    /// the internal hosts to match.
    public struct TracingConfig: Codable {
        public var enabled: Bool?
        public var headerName: String?        // default "traceparent"
        public var allowlistHosts: [String]?  // exact host or *.suffix.com
        public var sampled: Bool?             // flags=01 when true (default true)
        enum CodingKeys: String, CodingKey {
            case enabled
            case headerName     = "header_name"
            case allowlistHosts = "allowlist_hosts"
            case sampled
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
        case version, endpoint, rules, tracing
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
                matchClassName: r.matchClassName,
                toName: r.toName,
                addProps: r.addProps?.unwrapped() ?? [:])
        }
    }

    /// Hand off the tracing block to UniTrack. No-op if the portal didn't send
    /// a `tracing` section. Apps usually just call this from the fetch
    /// callback alongside `setEventRules(toEventRules())`.
    public func applyTracing() {
        guard let t = tracing else { return }
        UniTrack.setTracing(
            enabled:        t.enabled ?? false,
            headerName:     t.headerName ?? "traceparent",
            allowlistHosts: t.allowlistHosts ?? [],
            sampled:        t.sampled ?? true)
    }

    // MARK: - Fetch + cache

    private static func cacheKey(_ apiKey: String) -> String { "unitrack.config.\(apiKey)" }

    /// Fetch config from the portal. Always calls `completion` exactly once with a
    /// usable config (fresh, cached, or `fallback`). Never blocks the main thread.
    ///
    /// `flavor` selects a per-build override block on the portal (dev /
    /// staging / beta / production). Pass it via build config so debug builds
    /// get staging endpoints, release builds get production, etc., without
    /// shipping different api_keys per flavor.
    public static func fetch(apiKey: String,
                             configURL: String,
                             flavor: String? = nil,
                             timeout: TimeInterval = 3,
                             fallback: UniTrackRemoteConfig? = nil,
                             completion: @escaping (UniTrackRemoteConfig) -> Void) {
        let resolveFailure: () -> UniTrackRemoteConfig = {
            cached(apiKey: apiKey) ?? fallback ?? .builtinDefault()
        }
        // Append ?flavor=... if provided. URLComponents handles existing query
        // strings (some operators paste configURL with ?api_key=... already).
        var finalURL = URL(string: configURL)
        if let flavor = flavor, !flavor.isEmpty,
           var comps = URLComponents(string: configURL) {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "flavor", value: flavor))
            comps.queryItems = items
            finalURL = comps.url
        }
        guard let url = finalURL else {
            completion(resolveFailure()); return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Header form too — apps behind a CDN that strips query strings still
        // get the right flavor block.
        if let flavor = flavor, !flavor.isEmpty {
            req.setValue(flavor, forHTTPHeaderField: "X-UniTrack-Flavor")
        }
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
