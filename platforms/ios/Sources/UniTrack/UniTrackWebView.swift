// UniTrackWebView.swift
//
// Auto-capture WebView opens + navigations on iOS without per-call
// instrumentation.
//
// Strategy: swizzle WKWebView.load(_:) — every WKWebView (in-app browser,
// SFSafariViewController fallback, third-party SDK web shells) funnels
// through this single method, so one swizzle catches them all.
//
// Events emitted:
//   webview_open     — fires when an URL is first loaded into a WKWebView.
//                      Carries the URL string.
//
// Why not delegate-swizzling for `didFinish`: navigation delegate is
// per-instance and the app may set its own delegate later → races. The
// load(_:) call is enough to capture the user-facing event ("a WebView
// opened with this URL") without fighting the app's delegate setup.

import Foundation
import WebKit

public enum UniTrackWebView {

    /// Install the WKWebView swizzle. Call once at startup (after UniTrack.initialize).
    /// Subsequent calls are no-ops.
    public static func install() {
        Self.installOnce
    }

    // Lazy-init token: first read triggers the swizzle exactly once even if
    // install() is called from multiple threads.
    private static let installOnce: Void = {
        swizzleLoad()
    }()

    private static func swizzleLoad() {
        let cls: AnyClass = WKWebView.self
        let original = #selector(WKWebView.load(_:))
        let replacement = #selector(WKWebView.ut_load(_:))
        guard let m1 = class_getInstanceMethod(cls, original),
              let m2 = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(m1, m2)
    }
}

extension WKWebView {

    /// Swapped in for WKWebView.load(_:) by UniTrackWebView.install(). Forwards
    /// to the real implementation (now reachable under this same name after
    /// exchange), then logs the URL.
    @objc func ut_load(_ request: URLRequest) -> WKNavigation? {
        // After method_exchangeImplementations this call hits the ORIGINAL
        // load implementation, not ourselves.
        let nav = self.ut_load(request)
        if let url = request.url?.absoluteString, !url.isEmpty {
            UniTrack.trackWebViewOpen(url)
        }
        return nav
    }
}
