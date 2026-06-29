// UniTrackOpenURL.swift
//
// Auto-capture outgoing URL opens (third-party app launches, system browser
// launches, scheme:// hops to Zalo/Maps/Telegram).
//
// We swizzle UIApplication.open(_:options:completionHandler:) — the single
// funnel for every outbound URL the app asks iOS to handle. From the URL's
// scheme we decide:
//   - http / https  →  third_party_open(target: "browser") — Safari / SFSVC
//                      fallback. Apps that route to in-app WKWebView fire
//                      webview_open instead (Phase 5).
//   - tel:          →  third_party_open(target: "phone")
//   - mailto:       →  third_party_open(target: "mail")
//   - sms:          →  third_party_open(target: "sms")
//   - <other>://    →  third_party_open(target: "<scheme>") — Zalo, Maps,
//                      Telegram, custom universal-link receiver, …
//
// The "target" + the URL go into the event so the portal can group
// "user tapped a Zalo link" vs "user tapped a tel: link".

import Foundation
import UIKit

public enum UniTrackOpenURL {

    /// Install the swizzle. Call once at startup (after UniTrack.initialize).
    /// Multiple calls are no-ops via `installOnce`.
    public static func install() {
        _ = Self.installOnce
    }

    private static let installOnce: Void = {
        // Idempotent — see SwizzleHelper. Two modules calling install()
        // independently should land one swap, not zero.
        SwizzleHelper.swizzleInstanceMethod(
            cls: UIApplication.self,
            original: #selector(UIApplication.open(_:options:completionHandler:)),
            replacement: #selector(UIApplication.ut_open(_:options:completionHandler:)))
    }()

    /// Classify a URL's scheme into a target tag. Public so external code
    /// (e.g. a manual call) can match the same categorisation.
    public static func classify(_ url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "http", "https": return "browser"
        case "tel":           return "phone"
        case "mailto":        return "mail"
        case "sms":           return "sms"
        case .none, .some(""): return "unknown"
        case .some(let s):    return s            // zalo / googlemaps / fb-messenger / …
        }
    }
}

extension UIApplication {

    /// Swizzled replacement for UIApplication.open(_:options:completionHandler:).
    /// After method_exchangeImplementations, this name refers to UniTrack and
    /// `self.ut_open(...)` reaches the ORIGINAL implementation.
    @objc func ut_open(_ url: URL,
                       options: [UIApplication.OpenExternalURLOptionsKey: Any],
                       completionHandler completion: ((Bool) -> Void)?) {
        UniTrack.track("third_party_open", properties: [
            "target": UniTrackOpenURL.classify(url),
            "url":    url.absoluteString,
            "scheme": url.scheme ?? "",
        ])
        self.ut_open(url, options: options, completionHandler: completion)
    }
}
