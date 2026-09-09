// SceneDelegate.swift
//
// Mount 1 RCTRootView làm root view. Bundle JS load từ metro bundler
// (jsBundleURL(forBundleRoot: "index")) khi debug. Release build sẽ dùng
// jsBundleURL(forResource: "main.jsbundle").
//
// RN bridge khởi tạo → gọi UniTrack.initialize() từ JS App.tsx (nếu có).
// Nhưng bên trong RNUniTrack.swift, initialize() no-op khi HostProxy.isCoResident
// = true (đã set từ AppDelegate ở trên).

import UIKit
import React

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let jsCodeLocation: URL
        #if DEBUG
        jsCodeLocation = URL(string: "http://localhost:8081/index.bundle?platform=ios&dev=true&minify=false")!
        #else
        jsCodeLocation = Bundle.main.url(forResource: "main.jsbundle", withExtension: nil)!
        #endif

        let rootView = RCTRootView(
            bundleURL:    jsCodeLocation,
            moduleName:   "UniTrackRNHost",
            initialProperties: nil,
            launchOptions: nil
        )
        rootView.backgroundColor = UIColor(red: 13/255, green: 17/255, blue: 23/255, alpha: 1)

        let vc = UIViewController()
        vc.view = rootView

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = vc
        window?.makeKeyAndVisible()
    }
}
