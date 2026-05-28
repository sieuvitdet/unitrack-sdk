// ControlSwizzler.swift
//
// Swizzles `UIControl.sendAction(_:to:for:)` so every UIControl tap
// (UIButton, UISwitch, UISegmentedControl, …) is auto-tracked.
//
// Resolution order for element_key:
//   1. accessibilityIdentifier
//   2. restorationIdentifier
//   3. UIButton.title(for: .normal)
//   4. "ClassName"

import UIKit
import ObjectiveC.runtime

enum ControlSwizzler {
    static let installed: Void = {
        let cls = UIControl.self
        guard let m1 = class_getInstanceMethod(cls,
                #selector(UIControl.sendAction(_:to:for:))),
              let m2 = class_getInstanceMethod(cls,
                #selector(UIControl.ut_sendAction(_:to:for:))) else { return }
        method_exchangeImplementations(m1, m2)
    }()

    static func install() { _ = installed }
}

private extension UIControl {
    @objc func ut_sendAction(_ action: Selector,
                             to target: Any?,
                             for event: UIEvent?) {
        // Forward to original (swapped).
        self.ut_sendAction(action, to: target, for: event)

        // Decide whether to record this as a tap.
        //  • Touch-driven controls (UIButton via addTarget) carry a UIEvent with
        //    a touch in the .ended phase — record on .ended only (one per tap).
        //  • UIAction-driven controls (addAction(UIAction:), iOS 14+) call
        //    sendAction with event == nil — there's no touch to inspect, so we
        //    record once here (the action only fires on the actual interaction).
        //  • Skip continuous controls (UISlider/UIStepper) to avoid a flood.
        if self is UISlider || self is UIStepper { return }
        if let event = event {
            guard let touch = event.allTouches?.first,
                  touch.phase == .ended else { return }
        }
        // event == nil → UIAction path: fall through and record.

        let key = resolveKey(action: action)
        let screen = currentScreenName()
        var extra: [String: Any] = [
            "type": String(describing: type(of: self))
        ]
        if let btn = self as? UIButton, let t = btn.title(for: .normal) {
            extra["title"] = t
        }
        UniTrack.track("tap", properties: [
            "element_key": key,
            "screen":      screen,
            "extra":       extra
        ])
    }

    private func resolveKey(action: Selector) -> String {
        if let id = accessibilityIdentifier, !id.isEmpty { return id }
        if let id = restorationIdentifier, !id.isEmpty   { return id }
        if let btn = self as? UIButton,
           let t = btn.title(for: .normal), !t.isEmpty   { return "btn:\(t)" }
        return String(describing: type(of: self)) + "#" + NSStringFromSelector(action)
    }

    private func currentScreenName() -> String {
        // Walk responder chain to find the owning UIViewController. Use its
        // class-based screen name (NOT title, which is often a dynamic string
        // like a camera name — that produced the bogus "Phòng khách" screen).
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc.ut_screenName }
            r = next
        }
        return ""
    }
}
