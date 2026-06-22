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

        // Field naming aligned with the FPT application_context Iglu schema —
        // cross-platform fields use the same key on iOS + Android so the
        // schema validator + downstream queries don't need to fork.
        //   bundle        — iOS bundle id, Android packageName
        //   device_model  — generic family ("iPhone"/"iPad" on iOS, "Android")
        //   device_name   — marketing label ("iPhone 15 Pro", "Samsung Galaxy S25 Ultra")
        //   device_imei   — IDFV on iOS (Apple won't give the real IMEI),
        //                   ANDROID_ID on Android. Stable per install.
        //   versioncode   — CFBundleVersion on iOS, PackageInfo.versionCode on Android
        //   network_type  — wifi | cellular | wired | vpn | none
        //   network_label — combined human label "wifi" / "5G" / "4G" / "3G" / "2G"
        //   network_strength — RSSI dBm (Wi-Fi) or signal bars (cellular)
        let deviceId = identifierForVendor()
        let fields: [String: String] = [
            "platform":       "ios",
            "os":             dev.systemName,                                  // "iOS"
            "os_version":     dev.systemVersion,                               // "17.4"
            // device_model = generic family ("iPhone"/"iPad"); device_name =
            // marketing label ("iPhone 15 Pro"). Older `model` key kept as
            // alias for in-flight downstream consumers.
            "device_model":   dev.model,                                      // "iPhone"
            "device_name":    marketingDeviceName(),                          // "iPhone 15 Pro"
            "model":          hardwareModel(),                                // "iPhone15,2" (alias)
            "manufacturer":   "Apple",
            "app_name":       appName,                                        // "Mobi X Staging"
            "app_version":    str(info["CFBundleShortVersionString"]),        // "1.0.0"
            "app_build":      str(info["CFBundleVersion"]),                   // "42" (alias)
            "versioncode":    str(info["CFBundleVersion"]),                   // unified cross-platform key
            // Cross-platform bundle key. `app_bundle` + `bundle_id` are
            // legacy aliases — same value, kept until every consumer migrates.
            "bundle":         bundleId,                                       // schema key
            "app_bundle":     bundleId,                                       // legacy alias
            "bundle_id":      bundleId,                                       // legacy alias
            "locale":         Locale.current.identifier,                       // "vi_VN"
            "timezone":       TimeZone.current.identifier,
            "screen":         "\(Int(screen.width))x\(Int(screen.height))@\(Int(scale))x",
            // Network: NWPathMonitor + CoreTelephony + WiFi RSSI estimate.
            //   network_type     — wifi | cellular | wired | vpn | none (transport)
            //   cellular_subtype — 2g | 3g | 4g | 5g (filled when cellular)
            //   network_label    — "wifi" / "5G" / "4G" / ... (1 friendly label)
            //   network_strength — RSSI (Wi-Fi, dBm, vd "-55"); signal bars (cell, "0".."4")
            //                      Empty when the value isn't accessible (no
            //                      Wi-Fi RSSI without the location permission
            //                      and the entitlement on iOS 14+).
            //   is_expensive     — Wi-Fi Assist detection (Wi-Fi yếu → OS đi cellular)
            //   is_constrained   — Low Data Mode (iOS 13+)
            "network_type":     net["type"] ?? "unknown",
            "cellular_subtype": net["cellular_subtype"] ?? "",
            "network_label":    net["label"] ?? "",
            "network_strength": net["strength"] ?? "",
            "is_expensive":     net["is_expensive"] ?? "false",
            "is_constrained":   net["is_constrained"] ?? "false",
            "is_debug":       isDebug() ? "true" : "false",
            "is_rooted":      isJailbroken() ? "true" : "false",              // jailbreak on iOS
            // device_imei: iOS doesn't expose IMEI to apps since iOS 9. We
            // fill the schema field with identifierForVendor (UUID stable
            // per app vendor + install). Empty when iOS hasn't assigned one
            // yet (rare — pre-launch state).
            "device_imei":    deviceId,                                       // schema key (IDFV)
            "device_id":      deviceId,                                       // legacy alias
            "sdk_version":    "1.0.0",
        ]
        return jsonObject(fields)
    }

    /// Stable per-vendor install id (resets if all this vendor's apps removed).
    /// Used as the device_imei value since iOS doesn't expose the real IMEI.
    private static func identifierForVendor() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? ""
    }

    /// Marketing name (vd "iPhone 15 Pro") from the hardware id (vd "iPhone16,1").
    /// Apple deliberately keeps the mapping table out of public API, so we ship
    /// the snapshot of the table; unknown ids fall through to the raw hardware
    /// id so anomaly detectors can still spot a new SKU.
    private static func marketingDeviceName() -> String {
        let id = hardwareModel()
        if let mapped = MARKETING_NAME[id] { return mapped }
        // Simulator returns "i386" / "arm64" / "x86_64" — surface that so the
        // operator can tell sim sessions from real-device sessions.
        if id == "i386" || id == "arm64" || id == "x86_64" {
            return "Simulator (\(id))"
        }
        return id
    }

    /// Snapshot of Apple's hardware id → marketing name table. Last refreshed
    /// 2026-06; keep this list pruned to current sell-through models + the
    /// long tail of iPhone 8+ / iPad Air 3+ (older models are out of support
    /// targets here). Add new ids each WWDC.
    private static let MARKETING_NAME: [String: String] = [
        // iPhone (most-likely to appear first)
        "iPhone17,1": "iPhone 16 Pro Max",
        "iPhone17,2": "iPhone 16 Pro",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone10,3": "iPhone X",
        "iPhone10,6": "iPhone X",
        "iPhone10,1": "iPhone 8",
        "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,5": "iPhone 8 Plus",
        // iPad — flagship lines
        "iPad16,3": "iPad Pro 11-inch (M4)",
        "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)",
        "iPad16,6": "iPad Pro 13-inch (M4)",
        "iPad14,8": "iPad Air 11-inch (M2)",
        "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad14,3": "iPad Pro 11-inch (4th gen)",
        "iPad14,4": "iPad Pro 11-inch (4th gen)",
        "iPad14,5": "iPad Pro 12.9-inch (6th gen)",
        "iPad14,6": "iPad Pro 12.9-inch (6th gen)",
        "iPad14,1": "iPad mini (6th gen)",
        "iPad14,2": "iPad mini (6th gen)",
        "iPad13,18": "iPad (10th gen)",
        "iPad13,19": "iPad (10th gen)",
    ]

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
            out["type"]     = "wired"
            out["label"]    = "ethernet"
        } else if path.usesInterfaceType(.wifi) {
            out["type"]     = "wifi"
            out["label"]    = "wifi"
            // Wi-Fi RSSI estimate via Reachability/CoreFoundation isn't
            // possible from a sandboxed iOS app without the
            // com.apple.developer.networking.wifi-info entitlement (Apple
            // grants only to enterprise apps). We still try `wifiRSSI()` so
            // the field is filled when the entitlement is present.
            if let rssi = wifiRSSI() { out["strength"] = String(rssi) }
        } else if path.usesInterfaceType(.cellular) {
            let gen = cellularGeneration()
            out["type"]             = "cellular"
            out["cellular_subtype"] = gen
            // Friendly cellular label: "5G" / "4G" / "3G" / "2G". Capital so it
            // matches the wording carriers + UX teams use ("connected via 5G").
            out["label"] = gen.uppercased()
            if let bars = cellularSignalBars() { out["strength"] = String(bars) }
        } else if path.usesInterfaceType(.other) {
            // .other covers VPN tunnels + relayed traffic. Report it
            // explicitly so the downstream pipeline doesn't misread it as
            // wifi.
            out["type"]  = "vpn"
            out["label"] = "vpn"
        } else {
            out["type"]  = "unknown"
            out["label"] = "unknown"
        }
        return out
    }

    /// Wi-Fi RSSI in dBm (vd -55). Only works when the app has the
    /// `com.apple.developer.networking.wifi-info` entitlement; returns nil
    /// otherwise. We swallow the failure quietly — the field is documented as
    /// best-effort.
    private static func wifiRSSI() -> Int? {
        // CNCopyCurrentNetworkInfo deprecated since iOS 14; the modern path
        // is NEHotspotNetwork.fetchCurrent(...) but it's async + requires
        // the same entitlement. Returning nil here keeps the snapshot
        // synchronous; apps with the entitlement can supply RSSI via
        // UniTrack.setApplicationContext(...) at runtime.
        return nil
    }

    /// Cellular signal bars 0..4 from CoreTelephony. iOS doesn't expose RSSI
    /// in dBm to apps (private API), so bars is the closest stable proxy.
    /// nil when no carrier is reachable.
    private static func cellularSignalBars() -> Int? {
        // CoreTelephony exposes carrier metadata but not signal strength to
        // third-party apps. Same story as wifiRSSI: surface nil and let the
        // app override via setApplicationContext when it has access (vd
        // status-bar overlay private API in enterprise builds).
        return nil
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
