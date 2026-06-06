// ControlSwizzler.swift
//
// Auto-tracks UIControl taps (UIButton, UISwitch, UISegmentedControl, …).
//
// We swizzle `UIApplication.sendAction(_:to:from:for:)` — the single funnel that
// EVERY control action passes through, whether wired via the old target-action
// API (addTarget) OR the iOS 14+ `addAction(UIAction:)` API. The previous
// approach swizzled `UIControl.sendAction(_:to:for:)`, which UIAction-based
// buttons bypass — so demo buttons (built with addAction) were never captured
// and only the system back button (target-action) showed up.
//
// Resolution order for element_key:
//   1. accessibilityIdentifier
//   2. restorationIdentifier
//   3. UIButton title  ("btn:<title>")
//   4. "ClassName#selector"

import UIKit
import ObjectiveC.runtime

enum ControlSwizzler {
    static let installed: Void = {
        let cls = UIApplication.self
        guard let m1 = class_getInstanceMethod(cls,
                #selector(UIApplication.sendAction(_:to:from:for:))),
              let m2 = class_getInstanceMethod(cls,
                #selector(UIApplication.ut_sendAction(_:to:from:for:))) else { return }
        method_exchangeImplementations(m1, m2)
    }()

    static func install() { _ = installed }
}

private extension UIApplication {
    @objc func ut_sendAction(_ action: Selector,
                             to target: Any?,
                             from sender: Any?,
                             for event: UIEvent?) -> Bool {
        // Forward to original (swapped) and keep its return value.
        let handled = self.ut_sendAction(action, to: target, from: sender, for: event)

        // Only record taps that came from a UIControl (button/switch/segment…).
        // Skip continuous controls (slider/stepper) to avoid a flood.
        guard let control = sender as? UIControl,
              !(control is UISlider), !(control is UIStepper) else { return handled }

        let key = control.ut_resolveKey(action: action)
        let screen = control.ut_ownerScreenName()
        let cls = type(of: control)
        // class_name = FQCN (NSStringFromClass gives the demangled
        // "Module.Type" form on Swift classes, "UIButton" on ObjC). Bundle(for:)
        // returns the bundle the class was loaded from — UIKit's bundle is
        // "com.apple.UIKit", an app-defined subclass returns the app's main
        // bundle identifier. That's our `package`.
        let className   = NSStringFromClass(cls)
        let pkg         = Bundle(for: cls).bundleIdentifier ?? ""
        var extra: [String: Any] = ["type": String(describing: cls)]
        if let btn = control as? UIButton, let t = btn.title(for: .normal) { extra["title"] = t }
        // Use the convention name "click" (not "tap") so the Snowplow provider
        // maps via portal `event_names.click` (default → `event_click`) and the
        // schema URI lands at iglu:<vendor>/event_click/jsonschema/<v>. App
        // code that needs a different business event for a specific button
        // still uses a Phase-2 rewrite rule (match_event=click + element_key).
        // Trace the catch so a "trackTaps stays silent" bug is one log line
        // away from a diagnosis (swizzler not installed? installed but the
        // sendAction funnel never gets called? -> answer is "yes, but you're
        // tapping a non-UIControl").
        UniTrack.log("[UniTrack] tap captured key=%@ screen=%@ class=%@", key, screen, className)
        UniTrack.track("click", properties: [
            "element_key": key,
            "screen":      screen,
            "class_name":  className,
            "framework":   "uikit",
            "package":     pkg,
            "extra":       extra,
        ])
        return handled
    }
}

private extension UIControl {
    func ut_resolveKey(action: Selector) -> String {
        if let id = accessibilityIdentifier, !id.isEmpty { return id }
        if let id = restorationIdentifier, !id.isEmpty   { return id }
        if let btn = self as? UIButton,
           let t = btn.title(for: .normal), !t.isEmpty   { return "btn:\(t)" }
        return String(describing: type(of: self)) + "#" + NSStringFromSelector(action)
    }

    func ut_ownerScreenName() -> String {
        // Walk the responder chain to the owning UIViewController and use its
        // class-based screen name (NOT title, which is a dynamic display string).
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc.ut_screenName }
            r = next
        }
        return ""
    }
}
