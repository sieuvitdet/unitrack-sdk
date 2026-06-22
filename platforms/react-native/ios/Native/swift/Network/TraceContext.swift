// TraceContext.swift
//
// Swift wrapper around the C core's W3C trace-context helpers
// (`ut_new_trace` + `ut_format_traceparent`). Used by UniTrackURLProtocol
// to inject `traceparent` headers on outbound HTTP calls, and exposed
// publicly so app code can mint a trace_id for non-HTTP boundaries
// (push payload, deep-link → backend correlation).
//
// Why a wrapper: C's ut_trace_ids exposes char arrays; Swift consumers
// want Strings. This file converts once at the boundary.

import Foundation
#if canImport(UniTrackCore)
import UniTrackCore
#endif

public struct UniTrackTraceIds: Equatable {
    public let traceId: String   // 32 lowercase hex
    public let spanId:  String   // 16 lowercase hex
}

public enum UniTrackTracing {

    /// Mint a fresh (trace_id, span_id) pair — one root span per outbound call.
    public static func newTrace() -> UniTrackTraceIds {
        var ids = ut_new_trace()
        let trace = withUnsafePointer(to: &ids.trace_id) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: 33) { String(cString: $0) }
        }
        let span = withUnsafePointer(to: &ids.span_id) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
        }
        return UniTrackTraceIds(traceId: trace, spanId: span)
    }

    /// Format the W3C header value `00-<trace>-<span>-<flags>`. Cheap — no
    /// allocation beyond the result String.
    public static func traceparent(_ ids: UniTrackTraceIds, sampled: Bool = true) -> String {
        return "00-\(ids.traceId)-\(ids.spanId)-\(sampled ? "01" : "00")"
    }

    /// Decide if the SDK may inject `traceparent` on a request to `host`.
    /// Rules (in order):
    ///   1) `host` is nil/empty → no.
    ///   2) `allowlist` is empty → no (default fail-closed — we don't want
    ///      `traceparent` leaking to Firebase / Maps / CDNs the moment someone
    ///      flips `tracing.enabled` without thinking about hosts).
    ///   3) any entry matches the host exactly, OR starts with `*.` and the
    ///      host ends with the suffix (e.g. `*.mobix.asia` matches both
    ///      `api.mobix.asia` and `cdn.mobix.asia`).
    public static func shouldInject(host: String?, allowlist: [String]) -> Bool {
        guard let host = host, !host.isEmpty, !allowlist.isEmpty else { return false }
        let h = host.lowercased()
        for raw in allowlist {
            let pat = raw.lowercased()
            if pat == h { return true }
            if pat.hasPrefix("*.") {
                let suffix = String(pat.dropFirst(1))   // ".mobix.asia"
                if h.hasSuffix(suffix) || h == String(suffix.dropFirst()) { return true }
            }
        }
        return false
    }
}
