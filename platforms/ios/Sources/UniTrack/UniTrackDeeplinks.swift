// UniTrackDeeplinks.swift
//
// Drop-in deeplink auto-capture for iOS. Without this, the app has to call
// UniTrack.trackDeeplink(...) by hand from every entry point (app delegate
// openURL, scene delegate openURLContexts, NSUserActivity for universal
// links). With this installed once at startup, every URL/Universal Link
// that opens the app is captured.
//
// Two integration styles:
//
//   1) From your AppDelegate (UIKit):
//        UniTrackDeeplinks.install()
//
//      then in `application(_:open:options:)` and
//      `application(_:continue:restorationHandler:)` call:
//        UniTrackDeeplinks.handle(openURL: url)
//        UniTrackDeeplinks.handle(userActivity: userActivity)
//
//   2) From SceneDelegate:
//        for ctx in openURLContexts { UniTrackDeeplinks.handle(openURL: ctx.url) }
//        UniTrackDeeplinks.handle(userActivity: userActivity)
//
// We intentionally don't swizzle the AppDelegate — Apple's app-launch
// flow is fragile and SwiftUI apps may not have a UIApplicationDelegate
// at all. The two `handle(...)` calls are a one-liner per entry point.

import Foundation

public enum UniTrackDeeplinks {

    /// Install. Currently a no-op marker — kept so apps wire one symbol and
    /// can later upgrade to automatic capture without API change.
    public static func install() {
        // Reserved for future auto-install (e.g. swizzling
        // UIApplication.delegate methods once we trust the launch sequence).
    }

    /// Forward an URL that opened the app from the system (custom scheme).
    /// Call from `application(_:open:options:)` or SceneDelegate's
    /// `scene(_:openURLContexts:)`.
    public static func handle(openURL url: URL) {
        UniTrack.trackDeeplink(url.absoluteString, source: "openURL")
    }

    /// Forward an NSUserActivity (universal link). Call from
    /// `application(_:continue:restorationHandler:)` or SceneDelegate's
    /// `scene(_:continue:)`. Only `NSUserActivityTypeBrowsingWeb` activities
    /// carry a webpageURL — everything else is silently ignored.
    public static func handle(userActivity activity: NSUserActivity) {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL else { return }
        UniTrack.trackDeeplink(url.absoluteString, source: "universal_link")
    }
}
