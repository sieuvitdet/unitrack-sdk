// UniTrackValueResolver.swift
//
// One API for the app to read runtime-tunable values: feature flags,
// experiment buckets, A/B copy, threshold knobs. The SDK consults sources in
// this order and returns the first hit:
//
//   1. Portal `sdk_config.custom_values[key]` — operator-edited via the
//      portal Config tab, persisted on the server, fetched at launch.
//   2. Any registered RemoteValueProvider (Firebase RemoteConfig, etc.) —
//      legacy / fallback for keys not yet migrated to the portal.
//   3. The defaultValue the call site supplied.
//
// Putting the portal first means an operator can override anything Firebase
// RC also defines without touching the app or the Firebase Console — useful
// when migrating off Firebase incrementally, and for incidents where you
// need to flip a value faster than a Firebase RC publish cycle.
//
// Usage:
//   let copy: String = UniTrack.getRemoteValue("home_banner_copy", default: "Welcome")
//   let bucket: Int  = UniTrack.getRemoteValue("ab_bucket", default: 0)
//   let enabled: Bool = UniTrack.getRemoteValue("feature_x", default: false)

import Foundation

/// Conformed by analytics providers that also expose a remote-config bag
/// (vd custom adapter wrap Firebase RemoteConfig). Resolver iterates over
/// every registered provider that conforms and returns the first non-nil hit.
public protocol RemoteValueProvider: AnyObject {
    /// Look up `key` and return it as `T` if available. Return nil to defer
    /// to the next provider / the default value.
    func getRemoteValue<T>(_ key: String) -> T?
}

public extension UniTrack {
    /// Resolve a runtime value, falling back through portal config → registered
    /// providers → defaultValue. Synchronous + safe to call from any thread.
    static func getRemoteValue<T>(_ key: String, default defaultValue: T) -> T {
        if let v: T = portalRemoteValue(key) { return v }
        for provider in shared.providers {
            if let rcProvider = provider as? RemoteValueProvider,
               let v: T = rcProvider.getRemoteValue(key) {
                return v
            }
        }
        return defaultValue
    }

    /// Pull `key` out of `UniTrackRemoteConfig.latest?.sdkConfig.customValues`
    /// and coerce to T. Returns nil if no fetch has happened yet, the key is
    /// missing, or the value can't be cast to T (e.g. portal stored a String
    /// but the app asked for Int — that's a config bug, surfaced by the call
    /// site falling back to default).
    private static func portalRemoteValue<T>(_ key: String) -> T? {
        guard let bag = UniTrackRemoteConfig.latest?.sdkConfig.customValues,
              let raw = bag[key]?.value else { return nil }
        // The portal serializes JSON, so values arrive as Swift natives the
        // way JSONSerialization decodes them: NSNumber for ints/doubles/bools,
        // String for strings, NSArray/NSDictionary for nested structures.
        if let direct = raw as? T { return direct }
        // Number-shape coercions — JSON has no Int/Double distinction.
        if T.self == Int.self,    let n = raw as? NSNumber { return n.intValue as? T }
        if T.self == Double.self, let n = raw as? NSNumber { return n.doubleValue as? T }
        if T.self == Bool.self,   let n = raw as? NSNumber { return n.boolValue as? T }
        if T.self == String.self, let n = raw as? NSNumber { return n.stringValue as? T }
        return nil
    }
}
