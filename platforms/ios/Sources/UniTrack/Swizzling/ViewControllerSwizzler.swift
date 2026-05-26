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

    // Framework containers create noise — skip them for both events.
    var ut_isSkippedContainer: Bool {
        let skipped: Set<String> = [
            "UINavigationController", "UITabBarController",
            "UISplitViewController", "UIPageViewController",
            "UIInputWindowController", "UICompatibilityInputViewController",
            "UIAlertController",
        ]
        return skipped.contains(String(describing: type(of: self)))
    }

    // Use the controller's class name as the stable analytics screen name. (We
    // intentionally do NOT use `title`, which is often a localized navbar string
    // and not a stable key.) Strip the Swift module prefix so the name is
    // consistent — `type(of:)` can yield "MyApp.HomeVC" or "HomeVC" depending on
    // context; we always want the bare class name.
    var ut_screenName: String {
        let full = String(describing: type(of: self))
        return full.split(separator: ".").last.map(String.init) ?? full
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
        if !ut_loadReported, ut_loadStart > 0 {
            ut_loadReported = true
            let ms = Int((CACurrentMediaTime() - ut_loadStart) * 1000)
            UniTrack.track("screen_load_completed",
                           properties: ["screen": screen, "load_ms": ms])
        }
    }
}
