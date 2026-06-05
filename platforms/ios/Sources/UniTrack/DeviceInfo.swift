// DeviceInfo.swift
//
// Collects device + app metadata attached to every event (parity with what
// Firebase auto-collects). Gathered once at init and handed to the C core via
// ut_set_device_info; the core then stamps it onto each event payload.

import Foundation
import UIKit
import CoreTelephony
import Network

enum DeviceInfo {

    /// A JSON object string: {"os":"iOS","os_version":"17.4", ...}
    static func json() -> String {
        let dev = UIDevice.current
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale

        // User-facing app title: prefer CFBundleDisplayName (e.g. "Mobi X
        // Staging"), fall back to CFBundleName, then bundle name. So the
        // operator sees the same label they'd see under the home-screen icon
        // instead of just the bundle id.
        let appName = str(info["CFBundleDisplayName"]).isEmpty
            ? (str(info["CFBundleName"]).isEmpty ? "" : str(info["CFBundleName"]))
            : str(info["CFBundleDisplayName"])
        let bundleId = bundle.bundleIdentifier ?? ""
        let net = networkSnapshot()

        let fields: [String: String] = [
            "platform":       "ios",
            "os":             dev.systemName,                                  // "iOS"
            "os_version":     dev.systemVersion,                               // "17.4"
            "model":          hardwareModel(),                                 // "iPhone15,2"
            "device_name":    dev.model,                                       // "iPhone"
            "manufacturer":   "Apple",
            "app_name":       appName,                                         // "Mobi X Staging"
            "app_version":    str(info["CFBundleShortVersionString"]),         // "1.0.0"
            "app_build":      str(info["CFBundleVersion"]),                    // "42"
            // Cross-platform name (preferred) + iOS-specific alias. bundle_id
            // is kept for portal queries that haven't migrated yet — same
            // value as app_bundle, free to remove once everything reads the
            // new key.
            "app_bundle":     bundleId,
            "bundle_id":      bundleId,
            "locale":         Locale.current.identifier,                       // "vi_VN"
            "timezone":       TimeZone.current.identifier,
            "screen":         "\(Int(screen.width))x\(Int(screen.height))@\(Int(scale))x",
            // Network family captured once at init via NWPathMonitor. Camera
            // streaming team queries these together to attribute TTFF / buffer
            // events to underlying connectivity:
            //   network_type      — wifi | cellular | wired | vpn | none
            //   cellular_subtype  — 2g | 3g | 4g | 5g | "" (filled only when cellular)
            //   is_expensive      — true when traffic goes over a metered link;
            //                       on iOS this catches "Wi-Fi Assist" where the
            //                       OS silently falls back to cellular while the
            //                       status bar still shows the Wi-Fi icon.
            //   is_constrained    — true when Low Data Mode is on (iOS 13+).
            "network_type":     net["type"] ?? "unknown",
            "cellular_subtype": net["cellular_subtype"] ?? "",
            "is_expensive":     net["is_expensive"] ?? "false",
            "is_constrained":   net["is_constrained"] ?? "false",
            "is_debug":       isDebug() ? "true" : "false",
            "is_rooted":      isJailbroken() ? "true" : "false",              // jailbreak on iOS
            "device_id":      deviceId(),                                     // identifierForVendor
            "sdk_version":    "1.0.0",
        ]
        return jsonObject(fields)
    }

    /// Stable per-vendor install id (resets if all this vendor's apps removed).
    private static func deviceId() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? ""
    }

    private static func isDebug() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// One-shot snapshot via NWPathMonitor. Returns a dict the caller can
    /// merge into the device info bag — we report the primary transport plus
    /// the two NWPath signals that matter for streaming attribution:
    ///   • is_expensive   — Wi-Fi Assist on iOS silently switches to cellular
    ///                      when the Wi-Fi link can't carry data; the status
    ///                      bar still shows Wi-Fi but `path.isExpensive` flips
    ///                      to true. That's the field to trust over `type`.
    ///   • is_constrained — Low Data Mode (iOS 13+); user-toggled throttle.
    /// We start the monitor on a dedicated queue, wait briefly for the first
    /// path update, then cancel — keeping init synchronous + lifecycle clean.
    private static func networkSnapshot() -> [String: String] {
        let monitor = NWPathMonitor()
        let q = DispatchQueue(label: "unitrack.netcheck")
        let sem = DispatchSemaphore(value: 0)
        var captured: NWPath?
        monitor.pathUpdateHandler = { path in
            captured = path
            sem.signal()
        }
        monitor.start(queue: q)
        // Bounded wait: NWPathMonitor delivers the current path almost
        // immediately, but cap at 500ms so a stuck network daemon can't hang
        // app init.
        _ = sem.wait(timeout: .now() + .milliseconds(500))
        monitor.cancel()

        guard let path = captured else {
            return ["type": "unknown"]
        }
        if path.status != .satisfied {
            return ["type": "none"]
        }
        var out: [String: String] = [
            "is_expensive":   path.isExpensive ? "true" : "false",
            "is_constrained": path.isConstrained ? "true" : "false",
        ]
        // Wired check first — even on iOS this can be true for tethered
        // Ethernet adapters (rare but real). VPN must beat the others because
        // a VPN tunnel hides what the underlying transport actually is.
        if path.usesInterfaceType(.wiredEthernet) {
            out["type"] = "wired"
        } else if path.usesInterfaceType(.wifi) {
            out["type"] = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            out["type"] = "cellular"
            out["cellular_subtype"] = cellularGeneration()
        } else if path.usesInterfaceType(.other) {
            // .other covers VPN tunnels + relayed traffic. Report it
            // explicitly so the downstream pipeline doesn't misread it as
            // wifi.
            out["type"] = "vpn"
        } else {
            out["type"] = "unknown"
        }
        return out
    }

    /// Map the current radio access technology to a generation label.
    /// Falls back to "cellular" if the RAT can't be determined.
    private static func cellularGeneration() -> String {
        let info = CTTelephonyNetworkInfo()
        var rat: String?
        if #available(iOS 12.0, *) {
            // Pick the active carrier's RAT (first available entry).
            rat = info.serviceCurrentRadioAccessTechnology?.values.first
        } else {
            rat = info.currentRadioAccessTechnology
        }
        guard let tech = rat else { return "cellular" }
        switch tech {
        case CTRadioAccessTechnologyGPRS,
             CTRadioAccessTechnologyEdge,
             CTRadioAccessTechnologyCDMA1x:
            return "2g"
        case CTRadioAccessTechnologyWCDMA,
             CTRadioAccessTechnologyHSDPA,
             CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyeHRPD,
             CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB:
            return "3g"
        case CTRadioAccessTechnologyLTE:
            return "4g"
        default:
            // 5G NR constants exist only on iOS 14.1+; compare by raw value so
            // this compiles on older SDKs too.
            if tech == "CTRadioAccessTechnologyNRNSA" || tech == "CTRadioAccessTechnologyNR" {
                return "5g"
            }
            return "cellular"
        }
    }

    /// Best-effort jailbreak detection (common file/sandbox checks).
    private static func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = ["/Applications/Cydia.app", "/bin/bash", "/usr/sbin/sshd",
                     "/etc/apt", "/private/var/lib/apt/"]
        for p in paths where FileManager.default.fileExists(atPath: p) { return true }
        // Can we write outside the sandbox?
        let probe = "/private/jailbreak_probe.txt"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            return true
        }
        return false
        #endif
    }

    /// e.g. "iPhone15,2" — the hardware identifier (not the marketing name).
    private static func hardwareModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine
    }

    private static func str(_ v: Any?) -> String {
        (v as? String) ?? ""
    }

    private static func jsonObject(_ dict: [String: String]) -> String {
        // All values are strings; build manually to avoid pulling Codable here.
        if let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
