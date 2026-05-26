// AppDelegate.swift
//
// THE ONLY TRACKING CODE IN THIS APP IS THESE FEW LINES.
//
// After UniTrack.initialize(...), the SDK's native swizzlers take over:
//   • Every UIViewController appearance  -> screen_view  (class/title name)
//   • Every UIControl tap (UIButton…)    -> tap          (identifier/title)
//   • Every URLSession network call      -> network_request
//   • App foreground/background, memory warnings, crashes -> auto
//
// None of the view controllers below contain any tracking calls — that is the
// whole point: on native iOS, the SDK captures taps + screens automatically
// because the UI is real UIKit (UIButton / UIViewController), which is exactly
// what the swizzlers hook.

import UIKit
import UniTrack

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions
                     launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        var config = UniTrack.Config()
        config.endpoint        = "https://mobix.asia/event-tracking-mobile/v1/events"
        config.batchSize       = 5       // small so events show up fast in the demo
        config.flushIntervalMs = 2000
        config.samplingRate    = 1.0
        config.autoCapture     = true
        config.logLevel        = .info
        UniTrack.initialize(apiKey: "mobix-ios-uikit-demo", config: config)

        window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: HomeViewController())
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}
