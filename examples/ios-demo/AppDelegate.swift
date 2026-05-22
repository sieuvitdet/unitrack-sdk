// AppDelegate.swift — minimum iOS integration.
//
// Drop UniTrack.initialize into your AppDelegate. That's it.

import UIKit
import UniTrack

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions
                     launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        var config = UniTrack.Config()
        config.endpoint     = "https://ingest.example.com/v1/events"
        config.samplingRate = 1.0
        config.logLevel     = .info
        UniTrack.initialize(apiKey: "YOUR_API_KEY", config: config)

        // Optional — identify the user once they log in
        // UniTrack.identify(userId: "user-123", traits: ["plan": "pro"])

        return true
    }
}

// Anywhere in the app — every UIButton tap is auto-tracked.
// To make the analytics useful, give buttons stable identifiers:
//
//   buyButton.accessibilityIdentifier = "home_buy_now_btn"
//
// All URLSession network calls are auto-tracked too.
//
// For safe JSON parsing:
//
//   let user = try UniTrackDecoder.decode(User.self, from: data)
