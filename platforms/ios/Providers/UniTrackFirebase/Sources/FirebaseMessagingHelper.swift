// FirebaseMessagingHelper.swift
//
// Helpers the app calls from its existing UNUserNotificationCenterDelegate /
// MessagingDelegate methods to fan out push-notification + FCM-token events
// into UniTrack (and from there to Snowplow + the portal).
//
// We deliberately don't take over the delegate: every app worth migrating
// already owns those delegates (FPT Life keeps the FCM token in Keychain,
// the notification routing logic, etc.). Forcing a swizzle-based proxy here
// would conflict with that. Instead the app keeps its delegate and adds one
// line per callback.
//
// Usage in AppDelegate / FSSAppDelegate:
//
//   func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
//       UniTrackFirebaseMessaging.handleTokenUpdate(fcmToken)
//   }
//
//   func userNotificationCenter(_ center: UNUserNotificationCenter,
//                                didReceive response: UNNotificationResponse,
//                                withCompletionHandler completionHandler: @escaping () -> Void) {
//       UniTrackFirebaseMessaging.handleNotificationClicked(response)
//       completionHandler()
//   }
//
// When FirebaseMessaging isn't linked into the app (e.g. a non-push build),
// the whole file compiles down to no-op stubs so call sites stay portable.

import Foundation
import UniTrack
import UserNotifications

#if canImport(FirebaseMessaging)
import FirebaseMessaging

public enum UniTrackFirebaseMessaging {

    // Cache the latest token so identify() / setUser can attach it as a trait
    // without the app having to plumb the value through itself.
    private static let lock = NSLock()
    private static var cachedToken: String?

    /// Latest FCM token seen by the SDK (read-only). nil until the first
    /// token-update callback fires.
    public static var currentToken: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedToken
    }

    /// Call from `messaging(_:didReceiveRegistrationToken:)`. Fires
    /// `fcm_token_updated` whenever the token actually changes (Firebase will
    /// echo the same token on every cold start — we dedupe to avoid noise).
    public static func handleTokenUpdate(_ token: String?) {
        lock.lock()
        let prev = cachedToken
        cachedToken = token
        lock.unlock()

        guard let token = token, !token.isEmpty, token != prev else { return }
        var props: [String: Any] = ["fcm_token": token]
        if let p = prev, !p.isEmpty { props["prev_token"] = p }
        UniTrack.track("fcm_token_updated", properties: props)
    }

    /// Call from `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    /// Treated as the moment the user actually engaged with the push.
    public static func handleNotificationClicked(_ response: UNNotificationResponse) {
        let n = response.notification
        let userInfo = n.request.content.userInfo
        let (notifId, title, body, data) = extract(notification: n, userInfo: userInfo)
        UniTrack.trackNotification(
            state: "foreground",
            action: "clicked",
            title: title,
            body: body,
            notificationId: notifId,
            data: data
        )
    }

    /// Call from `userNotificationCenter(_:willPresent:withCompletionHandler:)`.
    /// Fires whenever a push arrives while the app is in the foreground (iOS
    /// asks the delegate whether to display it).
    public static func handleNotificationReceivedForeground(_ notification: UNNotification) {
        let userInfo = notification.request.content.userInfo
        let (notifId, title, body, data) = extract(notification: notification, userInfo: userInfo)
        UniTrack.trackNotification(
            state: "foreground",
            action: "received",
            title: title,
            body: body,
            notificationId: notifId,
            data: data
        )
    }

    /// Call from `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
    /// when the app is in background / silent push. No UNNotification object
    /// available there, so we work from the raw userInfo bag.
    public static func handleSilentPush(_ userInfo: [AnyHashable: Any]) {
        let notifId = userInfo["gcm.message_id"] as? String
            ?? userInfo["google.message_id"] as? String
            ?? ""
        let (title, body) = extractAlert(userInfo: userInfo)
        UniTrack.trackNotification(
            state: "background",
            action: "received",
            title: title,
            body: body,
            notificationId: notifId,
            data: jsonSafe(userInfo)
        )
    }

    // MARK: - Internal extraction helpers

    /// Pull the bits we want out of an iOS notification + its userInfo. We
    /// prefer fields off UNNotification when present (already decoded by iOS)
    /// and fall back to APS/data dictionaries.
    private static func extract(notification: UNNotification,
                                 userInfo: [AnyHashable: Any]) -> (String, String?, String?, [String: Any]) {
        let id = (userInfo["gcm.message_id"] as? String)
            ?? (userInfo["google.message_id"] as? String)
            ?? notification.request.identifier
        let content = notification.request.content
        let title: String? = content.title.isEmpty ? nil : content.title
        let body:  String? = content.body.isEmpty  ? nil : content.body
        // Use the iOS-decoded title/body when set; otherwise the helper below
        // tries to parse aps.alert directly.
        if title == nil && body == nil {
            let (t, b) = extractAlert(userInfo: userInfo)
            return (id, t, b, jsonSafe(userInfo))
        }
        return (id, title, body, jsonSafe(userInfo))
    }

    /// APS alert can be either a string (legacy) or a dict ({title, body}).
    private static func extractAlert(userInfo: [AnyHashable: Any]) -> (String?, String?) {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return (nil, nil) }
        if let alertStr = aps["alert"] as? String {
            return (nil, alertStr)
        }
        if let alert = aps["alert"] as? [AnyHashable: Any] {
            return (alert["title"] as? String, alert["body"] as? String)
        }
        return (nil, nil)
    }

    /// Strip non-JSON-safe values + coerce keys to String. APNs payloads
    /// occasionally include NSNumber / NSDate / nested AnyHashable keys; the
    /// portal's JSON encoder rejects those.
    private static func jsonSafe(_ bag: [AnyHashable: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in bag {
            let key = String(describing: k)
            if let s = v as? String       { out[key] = s; continue }
            if let n = v as? NSNumber     { out[key] = n; continue }
            if let b = v as? Bool         { out[key] = b; continue }
            if let arr = v as? [Any]      { out[key] = arr; continue }
            if let sub = v as? [AnyHashable: Any] { out[key] = jsonSafe(sub); continue }
            out[key] = String(describing: v)
        }
        return out
    }
}

#else

public enum UniTrackFirebaseMessaging {
    public static var currentToken: String? { nil }
    public static func handleTokenUpdate(_ token: String?) {}
    public static func handleNotificationClicked(_ response: UNNotificationResponse) {}
    public static func handleNotificationReceivedForeground(_ notification: UNNotification) {}
    public static func handleSilentPush(_ userInfo: [AnyHashable: Any]) {}
}

#endif
