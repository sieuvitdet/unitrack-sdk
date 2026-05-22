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

        // Only react to taps & value-change, skip continuous events.
        guard let touches = event?.allTouches,
              let touch = touches.first,
              touch.phase == .ended || touch.phase == .began else {
            return
        }

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
        // Walk responder chain to find owning UIViewController.
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController {
                return vc.title?.isEmpty == false ?
                    vc.title! : String(describing: type(of: vc))
            }
            r = next
        }
        return ""
    }
}
