// GestureRecognizerSwizzler.swift
//
// Auto-tracks UITapGestureRecognizer taps on plain UIViews.
//
// ControlSwizzler already catches UIControl taps (UIButton, UISwitch, …) via
// `UIApplication.sendAction(_:to:from:for:)`. But many apps use
// UITapGestureRecognizer on a plain UIView (image, label, custom view) for
// taps — those NEVER go through sendAction, so they were invisible until now.
//
// Strategy: swizzle `UIGestureRecognizer.setState(_:)`. UIKit calls setState
// EVERY time the recognizer transitions state (possible → began → recognized).
// When the new state is .recognized (= .ended for discrete recognizers like
// tap) we know the gesture just fired. We restrict to UITapGestureRecognizer
// to avoid noise from pan/pinch/swipe (continuous gestures fire setState many
// times per frame).
//
// Resolution order for element_key (same shape as ControlSwizzler):
//   1. The attached view's accessibilityIdentifier
//   2. The attached view's restorationIdentifier
//   3. UILabel text  ("lbl:<text>")
//   4. UIImageView   "img:<className>"
//   5. "ClassName#selector" (the first target+action pair if any)

import UIKit
import ObjectiveC.runtime

enum GestureRecognizerSwizzler {
    static let installed: Void = {
        let cls: AnyClass = UIGestureRecognizer.self
        guard let m1 = class_getInstanceMethod(cls,
                #selector(setter: UIGestureRecognizer.state)),
              let m2 = class_getInstanceMethod(cls,
                #selector(UIGestureRecognizer.ut_setState(_:))) else { return }
        method_exchangeImplementations(m1, m2)
    }()

    static func install() { _ = installed }
}

private extension UIGestureRecognizer {
    @objc func ut_setState(_ newState: UIGestureRecognizer.State) {
        // Forward to original (swapped) first so UIKit state machine stays
        // consistent — our reporting is a side effect.
        self.ut_setState(newState)

        // Only track tap recognizers reaching the recognized terminal state.
        // For UITapGestureRecognizer, `.recognized` == `.ended`. Skip every
        // other state (possible/began/changed/failed/cancelled) so we don't
        // double-fire mid-gesture. Skip non-tap recognizers entirely to
        // avoid pan/pinch/swipe spam.
        guard self is UITapGestureRecognizer,
              newState == .recognized else { return }

        let key       = ut_resolveKey()
        let screen    = ut_ownerScreenName()
        let viewCls   = view.map { type(of: $0) }
        let className = viewCls.map { NSStringFromClass($0) } ?? "UIView"
        let pkg       = viewCls.map { Bundle(for: $0).bundleIdentifier ?? "" } ?? ""

        var extra: [String: Any] = ["recognizer": String(describing: type(of: self))]
        if let v = view { extra["view_class"] = String(describing: type(of: v)) }
        if let lbl = view as? UILabel, let t = lbl.text, !t.isEmpty { extra["text"] = t }
        if let img = view as? UIImageView { extra["is_image"] = img.image != nil }

        UniTrack.log("[UniTrack] tap-gesture captured key=%@ screen=%@ class=%@",
                     key, screen, className)
        UniTrack.track("click", properties: [
            "element_key": key,
            "screen":      screen,
            "class_name":  className,
            "framework":   "uikit",
            "package":     pkg,
            "extra":       extra,
        ])
    }

    func ut_resolveKey() -> String {
        if let v = view {
            if let id = v.accessibilityIdentifier, !id.isEmpty { return id }
            if let id = v.restorationIdentifier, !id.isEmpty   { return id }
            if let lbl = v as? UILabel, let t = lbl.text, !t.isEmpty {
                return "lbl:\(t.prefix(40))"
            }
            if v is UIImageView { return "img:\(NSStringFromClass(type(of: v)))" }
        }
        // Last resort: pick the first registered target+action pair so the
        // backend at least sees which handler fires. UIKit doesn't expose
        // _targets publicly, so we peek via KVC against the private ivar.
        // Falls back gracefully when the runtime layout changes.
        let actionName = ut_firstActionName() ?? "tap"
        let viewCls = view.map { String(describing: type(of: $0)) } ?? "UIView"
        return "\(viewCls)#\(actionName)"
    }

    func ut_ownerScreenName() -> String {
        // Walk the view-owning responder chain to find the UIViewController.
        var r: UIResponder? = view
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc.ut_screenName }
            r = next
        }
        return ""
    }

    /// Best-effort peek at the recognizer's first target+action pair via the
    /// private `_targets` ivar. Returns nil when the layout differs (newer iOS
    /// versions, or when no target is attached). Wrapped in a guarded
    /// value(forKey:) so a missing key doesn't crash — we just lose the hint.
    func ut_firstActionName() -> String? {
        // Private API surface — keep it minimal + guard everything.
        let key = "_targets"
        guard responds(to: NSSelectorFromString(key)) ||
              class_getInstanceVariable(type(of: self), key) != nil else { return nil }
        let raw: Any? = (try? value(forKey: key))
        guard let arr = raw as? [Any], let first = arr.first else { return nil }
        // _UIGestureRecognizerTarget has `_action` (SEL) + `_target` (id).
        // value(forKey:"action") gets the selector wrapped as NSValue/string.
        if let s = (first as? NSObject)?.value(forKey: "action") {
            return String(describing: s)
        }
        return nil
    }
}
