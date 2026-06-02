// AppDelegate.swift — UniTrack camera demo entry point.
//
// SDK setup lives ENTIRELY here:
//   • CameraAnalytics.start()        → SDK init + native auto-capture
//   • UniTrackNotifications.wrap()   → auto-capture notification received/opened
//   • session_started / session_ended on lifecycle (taxonomy #1, #2)
//   • notification_permission_checked on launch (taxonomy #11)
//
// Every screen's screen_view + every button tap + every URLSession call is then
// captured automatically with no per-screen code.

import UIKit
import UserNotifications
import UniTrack

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // 1. Fetch remote config from the portal, THEN bring up UniTrack from it.
        //    Non-blocking: if the portal is unreachable, cached/default config is
        //    used so launch never stalls. Tracking that depends on the SDK runs
        //    inside the completion (after initialize()).
        CameraAnalytics.bootstrap {
            CameraAnalytics.identify(userId: "demo_user_42", plan: "b2c_premium")
            CameraAnalytics.sessionStarted()
            self.checkNotificationPermission()
            // Smoke-test hook — when launched with UNITRACK_AUTOFIRE_ALL=1, fire
            // every semantic helper once so the portal sees the full 30-event
            // taxonomy without UI driving. Off by default (production builds
            // won't see the env var set).
//            if ProcessInfo.processInfo.environment["UNITRACK_AUTOFIRE_ALL"] == "1" {
//                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
//                    CameraAnalytics.fireAllForSmokeTest()
//                }
//            }
        }

        // 2. Auto-capture push/local notifications (received + opened). Safe to
        //    wire before the SDK is up — events just queue once it initializes.
        let center = UNUserNotificationCenter.current()
        center.delegate = UniTrackNotifications.wrap(center.delegate)

        // 3. Root UI — a tab bar so the demo exercises many screens/flows.
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = RootTabBarController()
        window?.makeKeyAndVisible()
        return true
    }

    // taxonomy #11: notification_permission_checked
    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
            CameraAnalytics.notificationPermissionChecked(granted: granted)
        }
    }

    // taxonomy #2: session_ended when the app is backgrounded.
    func applicationDidEnterBackground(_ application: UIApplication) {
        CameraAnalytics.sessionEnded(reason: "backgrounded")
        UniTrack.flush()
    }

    // A fresh session when the app returns to the foreground.
    func applicationWillEnterForeground(_ application: UIApplication) {
        CameraAnalytics.sessionStarted()
    }
}
