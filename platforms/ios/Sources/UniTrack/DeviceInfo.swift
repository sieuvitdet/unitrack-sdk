// DeviceInfo.swift
//
// Collects device + app metadata attached to every event (parity with what
// Firebase auto-collects). Gathered once at init and handed to the C core via
// ut_set_device_info; the core then stamps it onto each event payload.

import Foundation
import UIKit
import SystemConfiguration
import CoreTelephony

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
            "network_type":   networkType(),                                  // wifi | cellular | 2g | 3g | 4g | 5g | none
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

    /// Reachability snapshot via SCNetworkReachability flags (no extra deps).
    /// For cellular we go one step further and map the radio access technology
    /// to a generation (3g/4g/5g) via CoreTelephony.
    private static func networkType() -> String {
        guard let reach = SCNetworkReachabilityCreateWithName(nil, "8.8.8.8") else {
            return "unknown"
        }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags),
              flags.contains(.reachable) else {
            return "none"
        }
        #if os(iOS)
        if flags.contains(.isWWAN) { return cellularGeneration() }
        #endif
        return "wifi"
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
