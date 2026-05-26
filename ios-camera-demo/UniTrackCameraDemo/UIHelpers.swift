// UIHelpers.swift — small UIKit helpers + a base VC that reports screen load
// time (taxonomy #26). Buttons get an accessibilityIdentifier so UniTrack's tap
// auto-capture keys taps by a meaningful name (not the selector).

import UIKit

/// Base VC: sets a readable title (so screen_view uses it) and reports
/// screen_load_completed once the view is laid out.
// NOTE: there is no more base "TrackedViewController". The SDK swizzles
// UIViewController.viewDidLoad/viewDidAppear, so EVERY plain UIViewController
// auto-emits `screen_view` (class name) + `screen_load_completed` (load time)
// with zero per-screen code. Demo screens just subclass UIViewController.

enum UI {
    /// A full-width action button. `id` becomes the tap auto-capture key
    /// (accessibilityIdentifier), and `action` runs the domain tracking call.
    static func button(_ title: String, id: String,
                       _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.accessibilityIdentifier = id          // ← UniTrack tap key
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        b.backgroundColor = .secondarySystemBackground
        b.layer.cornerRadius = 10
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    static func stack(_ views: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .vertical
        s.spacing = 12
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// Lay a vertical stack of buttons inside a scroll view on `vc`.
    static func fill(_ vc: UIViewController, with buttons: [UIView]) {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UI.stack(buttons)
        vc.view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])
    }
}
