// ViewControllerSwizzler.swift
//
// Swizzles UIViewController lifecycle to auto-capture, with NO per-controller code:
//   • viewDidLoad  → record a start timestamp (for load timing)
//   • viewDidAppear → emit `screen_view` (class name / title) AND
//                     `screen_load_completed` (viewDidLoad → first appearance ms)
// Installed once at SDK init.

import UIKit
import ObjectiveC.runtime

enum ViewControllerSwizzler {
    static let installed: Void = {
        swizzle(cls: UIViewController.self,
                from: #selector(UIViewController.viewDidLoad),
                to:   #selector(UIViewController.ut_viewDidLoad))
        swizzle(cls: UIViewController.self,
                from: #selector(UIViewController.viewDidAppear(_:)),
                to:   #selector(UIViewController.ut_viewDidAppear(_:)))
    }()

    static func install() { _ = installed }

    private static func swizzle(cls: AnyClass, from sel1: Selector, to sel2: Selector) {
        guard let m1 = class_getInstanceMethod(cls, sel1),
              let m2 = class_getInstanceMethod(cls, sel2) else { return }

        let added = class_addMethod(cls, sel1,
                                    method_getImplementation(m2),
                                    method_getTypeEncoding(m2))
        if added {
            class_replaceMethod(cls, sel2,
                                method_getImplementation(m1),
                                method_getTypeEncoding(m1))
        } else {
            method_exchangeImplementations(m1, m2)
        }
    }
}

private var utLoadStartKey: UInt8 = 0
private var utLoadReportedKey: UInt8 = 0

private extension UIViewController {
    var ut_loadStart: CFTimeInterval {
        get { (objc_getAssociatedObject(self, &utLoadStartKey) as? CFTimeInterval) ?? 0 }
        set { objc_setAssociatedObject(self, &utLoadStartKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var ut_loadReported: Bool {
        get { (objc_getAssociatedObject(self, &utLoadReportedKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &utLoadReportedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // Framework containers + system/private VCs create noise — skip them.
    var ut_isSkippedContainer: Bool {
        let name = String(describing: type(of: self))
        let skipped: Set<String> = [
            "UINavigationController", "UITabBarController",
            "UISplitViewController", "UIPageViewController",
            "UIInputWindowController", "UICompatibilityInputViewController",
            "UIAlertController",
            // System / framework chrome that isn't a real app screen.
            "UISceneHostingViewController", "_UISceneHostingViewController",
            "UITrackingElementWindowController", "UIEditingOverlayViewController",
            "UIPredictionViewController", "UISystemInputAssistantViewController",
            "FlutterViewController",   // the Flutter host — Dart routes name screens
            "HUD",
        ]
        if skipped.contains(name) { return true }
        // Private/framework VCs typically start with "_" — not app screens.
        if name.hasPrefix("_") { return true }
        return false
    }


    @objc func ut_viewDidLoad() {
        self.ut_viewDidLoad()                 // original (swapped)
        if !ut_isSkippedContainer { ut_loadStart = CACurrentMediaTime() }
    }

    @objc func ut_viewDidAppear(_ animated: Bool) {
        self.ut_viewDidAppear(animated)       // original (swapped)
        if ut_isSkippedContainer { return }

        let screen = ut_screenName
        UniTrack.setScreen(screen)            // screen_view

        // Load time: viewDidLoad → first appearance. Reported once per VC.
        // Event name resolves from UniTrack.screenLoadEventName (set during
        // _initialize from config.screenLoadEvent, in turn from portal
        // `sdk_config.screen_load_event`). Default keeps "screen_load_completed".
        if !ut_loadReported, ut_loadStart > 0 {
            ut_loadReported = true
            let ms = Int((CACurrentMediaTime() - ut_loadStart) * 1000)
            UniTrack.track(UniTrack.screenLoadEventName,
                           properties: ["screen": screen, "load_ms": ms])
        }
    }
}

// Shared screen-name resolver (internal — also used by ControlSwizzler for taps).
// Uses the controller's class name as the stable analytics screen name. We
// intentionally do NOT use `title`, which is often a dynamic string (e.g. a
// camera name) and not a stable key. Strip the Swift module prefix so the name
// is consistent — `type(of:)` can yield "MyApp.HomeVC" or "HomeVC".
extension UIViewController {
    var ut_screenName: String {
        let full = String(describing: type(of: self))
        return full.split(separator: ".").last.map(String.init) ?? full
    }
}
