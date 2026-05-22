// AppLifecycleObserver.swift
// Maps UIApplication foreground/background events to SDK events.

import UIKit

enum AppLifecycleObserver {
    static let installed: Void = {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { _ in
            UniTrack.track("app_foreground", properties: [:])
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { _ in
            UniTrack.track("app_background", properties: [:])
            UniTrack.flush()
        }
    }()

    static func install() { _ = installed }
}
