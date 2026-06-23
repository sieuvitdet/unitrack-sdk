// FirebaseAdapter — stamps UniTrack `session_id` onto every Firebase
// Analytics event WITHOUT importing Firebase.
//
// Why reflection: UniTrack core pod must stay 0-dep on Firebase. Apps that
//   - never use Firebase   → no transitive pull, no app-size hit
//   - use Firebase later   → adapter auto-detects at runtime, just works
//   - use Firebase already → 1 dòng `UniTrack.attachFirebaseAdapter()`
//
// Mechanism: lookup `FIRAnalytics` via `NSClassFromString`. Class-level
// methods are invoked via the Objective-C runtime (`perform(_:with:with:)`).
// If Firebase isn't linked, `create()` returns nil and the adapter is
// silently skipped.
//
// Portal toggle: respects `UniTrackRemoteConfig.latest?.firebase.enabled` —
// read at fire time, not attach time, so flipping the toggle realtime works.
import Foundation

public final class FirebaseAdapter: NSObject, AnalyticsProvider {

    public let providerId: String = "FirebaseAdapter"

    private let firClass: AnyClass
    private var lastStampedSessionId: String?

    /// Try to load `FIRAnalytics`. Returns nil if Firebase isn't linked into
    /// the app — adapter is silently disabled, app works as if it had no
    /// Firebase provider.
    public static func create() -> FirebaseAdapter? {
        guard let cls = NSClassFromString("FIRAnalytics") else {
            NSLog("[UniTrack] FirebaseAdapter: FIRAnalytics not linked → no-op")
            return nil
        }
        return FirebaseAdapter(firClass: cls)
    }

    private init(firClass: AnyClass) {
        self.firClass = firClass
        super.init()
    }

    public func initializeProvider() {
        // Set default params NGAY khi adapter attach — kể cả khi event đầu tiên
        // chưa fire qua UniTrack.track(). App gọi `Analytics.logEvent` thẳng
        // (bypass UniTrack) từ đây sẽ có session_id ngay.
        maybeStampSessionGlobals()
    }

    public func track(_ name: String, _ properties: [String: Any]) {
        guard isEnabled() else { return }
        maybeStampSessionGlobals()
        var params = properties.mapValues { coerce($0) }
        params["session_id"] = UniTrack.currentSessionId() as NSString
        invokeLogEvent(name: sanitize(name), params: params)
    }

    public func setUser(_ userId: String?, _ traits: [String: Any]) {
        guard isEnabled() else { return }
        invokeClassMethod(selector: NSSelectorFromString("setUserID:"),
                          arg1: userId as NSString?, arg2: nil)
        let setPropSel = NSSelectorFromString("setUserPropertyString:forName:")
        for (k, v) in traits {
            invokeClassMethod(selector: setPropSel,
                              arg1: String(describing: v) as NSString,
                              arg2: sanitize(k) as NSString)
        }
        // Identity đổi (login/logout) — re-stamp default params để session_id
        // không stale. UniTrack core có thể rotate session khi identity đổi
        // tuỳ business logic; gọi maybeStampSessionGlobals() đảm bảo Firebase
        // pick up giá trị mới.
        lastStampedSessionId = nil  // force re-stamp
        maybeStampSessionGlobals()
    }

    public func setScreen(_ name: String) { /* propagated via track(screen_view) */ }

    // MARK: - private

    private func maybeStampSessionGlobals() {
        let sid = UniTrack.currentSessionId()
        guard !sid.isEmpty, sid != lastStampedSessionId else { return }
        // 1) user_property — Firebase attribute mọi event session-level. Persist
        //    qua restart, dùng cho audience / segment.
        let setProp = NSSelectorFromString("setUserPropertyString:forName:")
        invokeClassMethod(selector: setProp,
                          arg1: sid as NSString,
                          arg2: "ut_session_id" as NSString)
        invokeClassMethod(selector: setProp,
                          arg1: String(UniTrack.sessionIndex()) as NSString,
                          arg2: "ut_session_index" as NSString)
        // 2) defaultEventParameters — Firebase tự merge vào MỌI event sau đây
        //    (cả event app gọi `Analytics.logEvent` thẳng, bypass UniTrack).
        //    Yêu cầu Firebase iOS SDK 8.4+. Bằng cách check `responds(to:)`
        //    bên `invokeClassMethod` — older SDK no-op không crash.
        let setDefault = NSSelectorFromString("setDefaultEventParameters:")
        let defaults: [String: Any] = [
            "session_id":    sid as NSString,
            "session_index": NSNumber(value: UniTrack.sessionIndex()),
        ]
        invokeClassMethod(selector: setDefault,
                          arg1: NSDictionary(dictionary: defaults),
                          arg2: nil)
        lastStampedSessionId = sid
    }

    private func isEnabled() -> Bool {
        // Default ON: the only way the adapter exists at all is the app
        // explicitly attached, so being defensive about no-config-yet states
        // (cold start, fetch in flight) means we still stamp until Portal
        // explicitly says off.
        return UniTrackRemoteConfig.latest?.firebase.enabled != false
    }

    /// Call `[FIRAnalytics logEventWithName:parameters:]`.
    private func invokeLogEvent(name: String, params: [String: Any]) {
        let sel = NSSelectorFromString("logEventWithName:parameters:")
        invokeClassMethod(selector: sel,
                          arg1: name as NSString,
                          arg2: NSDictionary(dictionary: params))
    }

    /// Invoke a class-level selector (0..2 object args) via the ObjC runtime.
    private func invokeClassMethod(selector: Selector, arg1: AnyObject?, arg2: AnyObject?) {
        guard firClass.responds(to: selector) else { return }
        let cls: AnyObject = firClass
        if arg2 != nil {
            _ = cls.perform(selector, with: arg1, with: arg2)
        } else if arg1 != nil {
            _ = cls.perform(selector, with: arg1)
        } else {
            _ = cls.perform(selector)
        }
    }

    /// Firebase rejects values that aren't NSString / NSNumber.
    private func coerce(_ v: Any) -> Any {
        switch v {
        case let s as String:  return s as NSString
        case let n as NSNumber: return n
        case let b as Bool:    return NSNumber(value: b)
        case let i as Int:     return NSNumber(value: i)
        case let d as Double:  return NSNumber(value: d)
        default:               return String(describing: v) as NSString
        }
    }

    /// Firebase: `[^A-Za-z0-9_]` rejected; cannot start with digit; max 40.
    private func sanitize(_ s: String) -> String {
        var out = ""
        for (i, c) in s.enumerated() {
            let ok = c.isLetter || c.isNumber || c == "_"
            out.append(ok ? c : "_")
            if i == 0 && c.isNumber { out = "_" + out }
        }
        return String(out.prefix(40))
    }
}
