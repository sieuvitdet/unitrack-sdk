// FirebaseCrashlyticsHelper.swift
//
// Thin façade so the app calls one API and gets both: Crashlytics records
// the error (with full symbolicated stack via the app's dSYM upload) AND
// UniTrack fires application_error through its convention pipeline (portal +
// Snowplow). The C++ signal-trap crash handler in UniTrack core stays
// independent — that fires on the NEXT launch with reason=signal, while this
// helper is for non-fatal `record(error:)` calls inside try/catch sites.
//
// Usage:
//   do { try riskyCall() }
//   catch { UniTrackFirebaseCrashlytics.recordError(error) }
//
// Breadcrumb-style log + custom keys (the Crashlytics features the C++ trap
// can't replicate from a signal handler):
//   UniTrackFirebaseCrashlytics.log("entering checkout flow step 2")
//   UniTrackFirebaseCrashlytics.setCustomKey("cart_size", 3)

import Foundation
import UniTrack

#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics

public enum UniTrackFirebaseCrashlytics {

    /// Record a non-fatal error. Forwards to Crashlytics for symbolication +
    /// fires `application_error` (is_fatal=false) so the portal + Snowplow
    /// see the same incident.
    public static func recordError(_ error: Error, userInfo: [String: Any]? = nil) {
        if let userInfo = userInfo {
            // Crashlytics' record(error:userInfo:) is not an overload — its
            // userInfo overload takes [String: Any]? on its own param. Use
            // setCustomValue for the bag so the keys appear on the report.
            for (k, v) in userInfo { Crashlytics.crashlytics().setCustomValue(v, forKey: k) }
        }
        Crashlytics.crashlytics().record(error: error)

        var props: [String: Any] = [
            "message":  error.localizedDescription,
            "is_fatal": false,
        ]
        if let domain = (error as NSError?)?.domain { props["exception_name"] = domain }
        if let code = (error as NSError?)?.code   { props["error_code"]    = code }
        if let userInfo = userInfo, !userInfo.isEmpty { props["context"] = userInfo }
        UniTrack.track("application_error", properties: props)
    }

    /// Attach a custom key to subsequent crash reports (breadcrumb context).
    /// Mirrors `Crashlytics.crashlytics().setCustomValue(_:forKey:)`.
    public static func setCustomKey(_ key: String, _ value: Any) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    /// Append a line to the Crashlytics log ring buffer. Surfaces in the
    /// crash report's "Logs" section.
    public static func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    /// Internal — called by FirebaseProvider.setUser to keep Crashlytics in
    /// sync with the identified UniTrack user. Public so test code can poke
    /// it directly if needed.
    public static func syncUser(_ userId: String?) {
        // setUserID accepts "" as the cleared state (Crashlytics treats empty
        // string as "no user"). Match that contract here so logout flows work.
        Crashlytics.crashlytics().setUserID(userId ?? "")
    }
}

#else

public enum UniTrackFirebaseCrashlytics {
    public static func recordError(_ error: Error, userInfo: [String: Any]? = nil) {
        // Even without Crashlytics, still report through UniTrack so portal +
        // Snowplow get the incident. App can switch crash backends later
        // without touching call sites.
        var props: [String: Any] = [
            "message":  error.localizedDescription,
            "is_fatal": false,
        ]
        if let userInfo = userInfo, !userInfo.isEmpty { props["context"] = userInfo }
        UniTrack.track("application_error", properties: props)
    }
    public static func setCustomKey(_ key: String, _ value: Any) {}
    public static func log(_ message: String) {}
    public static func syncUser(_ userId: String?) {}
}

#endif
