// ViewControllerSwizzler.swift
//
// Swizzles `UIViewController.viewDidAppear(_:)` to automatically emit a
// screen_view event with the controller's class name (or its `title`).
// Installed once at SDK init; no per-controller code required.

import UIKit
import ObjectiveC.runtime

enum ViewControllerSwizzler {
    static let installed: Void = {
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

private extension UIViewController {
    @objc func ut_viewDidAppear(_ animated: Bool) {
        // Calls the original implementation (swapped).
        self.ut_viewDidAppear(animated)

        // Skip framework containers — they create noise.
        let name = String(describing: type(of: self))
        let skipped: Set<String> = [
            "UINavigationController", "UITabBarController",
            "UISplitViewController", "UIPageViewController",
            "UIInputWindowController", "UICompatibilityInputViewController",
            "UIAlertController",
        ]
        if skipped.contains(name) { return }

        let display = self.title?.isEmpty == false ? self.title! : name
        UniTrack.setScreen(display)
    }
}
