// UniTrackNotifications.swift
//
// Drop-in notification auto-capture for iOS. The app wires this ONCE and every
// push/local notification is forwarded to UniTrack — no per-notification calls.
//
// Two integration styles:
//
//  1) Wrap your existing delegate (recommended — keeps your behaviour):
//
//        let center = UNUserNotificationCenter.current()
//        center.delegate = UniTrackNotifications.wrap(center.delegate)
//
//  2) Forward manually from your own delegate methods if you prefer:
//
//        UniTrackNotifications.capture(notification, action: .received)
//        UniTrackNotifications.capture(response.notification, action: .opened)
//
// "state" (foreground|background|silent) is derived automatically from the app
// state and the notification's alert content.

import Foundation
import UserNotifications
import UIKit

public enum UniTrackNotifications {

    public enum Action: String { case received, opened }

    /// Forward a single notification to UniTrack. State is inferred from the
    /// current app state and whether the notification carries visible content.
    public static func capture(_ notification: UNNotification, action: Action) {
        let content = notification.request.content
        let silent = content.title.isEmpty && content.body.isEmpty
        let state: String
        if silent {
            state = "silent"
        } else {
            state = (UIApplication.shared.applicationState == .active) ? "foreground" : "background"
        }
        UniTrack.trackNotification(
            state: state,
            action: action.rawValue,
            title: content.title.isEmpty ? nil : content.title,
            body: content.body.isEmpty ? nil : content.body
        )
    }

    /// Wrap an existing delegate so notifications are captured automatically
    /// while still forwarding every call to the original delegate. Pass the
    /// result back to `UNUserNotificationCenter.current().delegate`.
    public static func wrap(_ original: UNUserNotificationCenterDelegate?) -> UNUserNotificationCenterDelegate {
        return DelegateProxy(wrapping: original)
    }

    // A thin proxy: captures, then forwards to the app's real delegate.
    final class DelegateProxy: NSObject, UNUserNotificationCenterDelegate {
        private let inner: UNUserNotificationCenterDelegate?
        init(wrapping inner: UNUserNotificationCenterDelegate?) { self.inner = inner }

        // Foreground presentation.
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler:
                                        @escaping (UNNotificationPresentationOptions) -> Void) {
            UniTrackNotifications.capture(notification, action: .received)
            if let inner = inner {
                inner.userNotificationCenter?(center, willPresent: notification,
                                              withCompletionHandler: completionHandler)
            } else {
                // .banner is iOS 14+; .alert is the pre-14 equivalent.
                if #available(iOS 14.0, *) {
                    completionHandler([.banner, .sound])
                } else {
                    completionHandler([.alert, .sound])
                }
            }
        }

        // User tapped / acted on a delivered notification.
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            UniTrackNotifications.capture(response.notification, action: .opened)
            if let inner = inner {
                inner.userNotificationCenter?(center, didReceive: response,
                                              withCompletionHandler: completionHandler)
            } else {
                completionHandler()
            }
        }

        // Forward anything else (e.g. openSettingsFor) to the real delegate.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (inner?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if inner?.responds(to: aSelector) == true { return inner }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
