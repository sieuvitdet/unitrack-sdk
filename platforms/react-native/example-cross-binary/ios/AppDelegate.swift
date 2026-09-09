// AppDelegate.swift
//
// Native iOS host cho RN cross-binary test bed.
//
// Init UniTrack native TRƯỚC khi bất kỳ view controller nào load — như FPT
// Life bootstrap ở FLifeApp / FPTLifeAppDelegate. RN plugin sau đó detect
// co-resident + piggyback (KHÔNG init UniTrack riêng).

import UIKit
import UniTrack

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        var cfg = UniTrack.Config()
        cfg.endpoint         = "https://event-tracking-portal.mobix.asia/ingest"
        cfg.batchSize        = 20
        cfg.flushIntervalMs  = 3000
        cfg.autoCapture      = true
        cfg.trackScreens     = true
        cfg.trackTaps        = true

        UniTrack.initialize(apiKey: "utk_rn_cross_binary_test", config: cfg)
        NSLog("[UniTrackHost] initialized session_id=%@", UniTrack.currentSessionId())

        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}
