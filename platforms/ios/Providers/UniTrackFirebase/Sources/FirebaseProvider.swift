// FirebaseProvider — forwards every UniTrack event to Firebase Analytics.
//
// Prerequisites (standard Firebase iOS setup, done by the app):
//   • GoogleService-Info.plist added to the app target.
//
//   UniTrack.addProvider(FirebaseProvider())
//   UniTrack.initialize(apiKey: ...)
//
// Firebase imposes strict naming rules (event/param names ≤40 chars,
// alphanumeric + underscore, start with a letter; values String/number), so
// names and parameters are sanitized.

import Foundation
import UniTrack
#if canImport(FirebaseAnalytics)
import FirebaseCore
import FirebaseAnalytics

public final class FirebaseProvider: AnalyticsProvider {

    private let portalEndpoint: String?
    private let portalApiKey: String?

    /// "Super properties": custom fields merged into EVERY event sent to
    /// Firebase (e.g. app_env, tenant_id). Event-specific properties win on key
    /// conflicts. Mutable at runtime via setSuperProperty / removeSuperProperty.
    private var superProperties: [String: Any]
    /// Firebase user properties to set at init (for audiences/segmentation).
    private let initialUserProperties: [String: Any]
    /// Optional runtime FirebaseOptions (from remote config). When set, the
    /// provider calls FirebaseApp.configure(options:) instead of relying on a
    /// bundled GoogleService-Info.plist — so the values live on the portal.
    public struct Options {
        public var googleAppID: String   // GOOGLE_APP_ID (e.g. 1:NNN:ios:xxx)
        public var gcmSenderID: String   // GCM_SENDER_ID
        public var apiKey: String?
        public var projectID: String?
        public var bundleID: String?
        public var storageBucket: String?
        public init(googleAppID: String, gcmSenderID: String, apiKey: String? = nil,
                    projectID: String? = nil, bundleID: String? = nil, storageBucket: String? = nil) {
            self.googleAppID = googleAppID; self.gcmSenderID = gcmSenderID
            self.apiKey = apiKey; self.projectID = projectID
            self.bundleID = bundleID; self.storageBucket = storageBucket
        }
    }
    private let runtimeOptions: Options?
    private let lock = NSLock()

    /// - firebaseOptions: when provided, Firebase is configured at runtime from
    ///   these portal values (no GoogleService-Info.plist needed). When nil, the
    ///   bundled plist is used.
    /// - portalEndpoint/portalApiKey: optional portal mirror (provider=firebase).
    /// - superProperties: merged into every event's parameters.
    /// - userProperties: Firebase setUserProperty at init (audience segmentation).
    public init(firebaseOptions: Options? = nil,
                portalEndpoint: String? = nil,
                portalApiKey: String? = nil,
                superProperties: [String: Any] = [:],
                userProperties: [String: Any] = [:]) {
        self.runtimeOptions = firebaseOptions
        self.portalEndpoint = portalEndpoint
        self.portalApiKey = portalApiKey
        self.superProperties = superProperties
        self.initialUserProperties = userProperties
    }

    /// Add/replace a super property at runtime (applies to subsequent events).
    public func setSuperProperty(_ key: String, _ value: Any) {
        lock.lock(); superProperties[key] = value; lock.unlock()
    }
    public func removeSuperProperty(_ key: String) {
        lock.lock(); superProperties.removeValue(forKey: key); lock.unlock()
    }
    /// Set a Firebase user property at runtime.
    public func setUserProperty(_ key: String, _ value: String?) {
        Analytics.setUserProperty(value, forName: sanitizeName(key))
    }

    public func initializeProvider() {
        // Configure Firebase. With runtime options (from the portal) we build a
        // FirebaseOptions and call configure(options:) — no bundled plist needed.
        // Otherwise fall back to the plist-based configure().
        if FirebaseApp.app() == nil {
            if let o = runtimeOptions {
                let opts = FirebaseOptions(googleAppID: o.googleAppID, gcmSenderID: o.gcmSenderID)
                if let v = o.apiKey { opts.apiKey = v }
                if let v = o.projectID { opts.projectID = v }
                if let v = o.bundleID { opts.bundleID = v }
                if let v = o.storageBucket { opts.storageBucket = v }
                FirebaseApp.configure(options: opts)
            } else {
                FirebaseApp.configure()
            }
        }
        // Don't let UniTrack capture our portal-mirror uploads (feedback loop).
        if let ep = portalEndpoint, let host = URL(string: ep)?.host {
            UniTrack.excludeFromNetworkCapture(urlContaining: host)
        }
        // CRUCIAL: Firebase Analytics itself POSTs measurement data to these
        // Google hosts. Without excluding them, UniTrack auto-captures each
        // Firebase upload as a network_request, which is then forwarded back to
        // Firebase/Snowplow → captured again → an endless amplifying loop.
        for host in [
            "app-analytics-services.com",      // GoogleAppMeasurement upload
            "app-measurement.com",
            "firebase-settings.crashlytics.com",
            "firebaseinstallations.googleapis.com",
            "firebaseremoteconfig.googleapis.com",
            "google-analytics.com",
            "analytics.google.com",
        ] {
            UniTrack.excludeFromNetworkCapture(urlContaining: host)
        }
        // Apply initial Firebase user properties (for audiences/segmentation).
        for (k, v) in initialUserProperties {
            Analytics.setUserProperty(stringify(v), forName: sanitizeName(k))
        }
        NSLog("[UniTrackFirebase] Firebase Analytics ready")
    }

    public func track(_ name: String, _ properties: [String: Any]) {
        // Merge super properties under the event's own (event props win).
        lock.lock(); let sup = superProperties; lock.unlock()
        var merged = sup
        for (k, v) in properties { merged[k] = v }
        Analytics.logEvent(sanitizeName(name), parameters: sanitizeParams(merged))
        mirrorToPortal(name, merged)
    }

    // Fire-and-forget copy to the portal, tagged provider=firebase.
    private func mirrorToPortal(_ name: String, _ properties: [String: Any]) {
        guard let ep = portalEndpoint, let key = portalApiKey,
              !ep.isEmpty, !key.isEmpty,
              let url = URL(string: ep + (ep.contains("?") ? "&" : "?") + "provider=firebase")
        else { return }
        let payload: [String: Any] = [
            "event_id": "\(Int(Date().timeIntervalSince1970 * 1_000_000))_\(name)",
            "event_name": name,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "properties": properties,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    public func setUser(_ userId: String?, _ traits: [String: Any]) {
        Analytics.setUserID(userId)
        for (k, v) in traits {
            Analytics.setUserProperty(stringify(v), forName: sanitizeName(k))
        }
    }

    public func setScreen(_ name: String) {
        Analytics.logEvent(AnalyticsEventScreenView,
                           parameters: [AnalyticsParameterScreenName: name])
    }

    // --- Firebase naming/value constraints ----------------------------------

    private func sanitizeName(_ name: String) -> String {
        var s = name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
                    .reduce("") { $0 + String($1) }
        if let first = s.first, !first.isLetter { s = "e_" + s }
        if s.count > 40 { s = String(s.prefix(40)) }
        return s
    }

    private func sanitizeParams(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in props {
            let key = sanitizeName(k)
            if v is NSNumber || v is String {
                if let str = v as? String, str.count > 100 {
                    out[key] = String(str.prefix(100))
                } else {
                    out[key] = v
                }
            } else {
                out[key] = stringify(v)
            }
        }
        return out
    }

    private func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        return String(describing: v)
    }
}
#else
public final class FirebaseProvider: AnalyticsProvider {
    public init() {}
    public func initializeProvider() {
        NSLog("[UniTrackFirebase] FirebaseAnalytics not available")
    }
    public func track(_ name: String, _ properties: [String: Any]) {}
    public func setUser(_ userId: String?, _ traits: [String: Any]) {}
    public func setScreen(_ name: String) {}
}
#endif

// MARK: - Remote config bridge (Firebase RemoteConfig → UniTrack)

#if canImport(FirebaseRemoteConfig)
import FirebaseRemoteConfig

/// FirebaseProvider doubles as a fallback for `UniTrack.getRemoteValue(...)`:
/// after the portal `sdk_config.custom_values` lookup misses, the resolver
/// asks each provider that conforms here. Returns nil for unknown keys so
/// the resolver moves on to the caller's defaultValue.
extension FirebaseProvider: RemoteValueProvider {
    public func getRemoteValue<T>(_ key: String) -> T? {
        // RemoteConfig.configValue(forKey:) always returns a value object
        // even for unknown keys (with `.source == .static`). Skip those so we
        // don't shadow the caller's default with Firebase's zero-value.
        let v = RemoteConfig.remoteConfig().configValue(forKey: key)
        guard v.source != .static else { return nil }
        if T.self == String.self { return v.stringValue as? T }
        if T.self == Int.self    { return v.numberValue.intValue as? T }
        if T.self == Double.self { return v.numberValue.doubleValue as? T }
        if T.self == Bool.self   { return v.boolValue as? T }
        return nil
    }
}

public extension FirebaseProvider {
    /// Convenience around `RemoteConfig.fetchAndActivate`. Call once at app
    /// startup (after `UniTrack.initialize`) so RC has values to serve when
    /// the resolver falls through to it. Completion fires on the main thread.
    static func fetchRemoteConfig(completion: ((Bool) -> Void)? = nil) {
        RemoteConfig.remoteConfig().fetchAndActivate { status, error in
            let ok = error == nil &&
                (status == .successFetchedFromRemote || status == .successUsingPreFetchedData)
            DispatchQueue.main.async { completion?(ok) }
        }
    }
}
#endif
