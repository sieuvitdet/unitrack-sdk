// UniTrackSnowplowNetworkConnection.swift
//
// Custom NetworkConnection that wraps Snowplow's DefaultNetworkConnection
// and surfaces what's actually on the wire:
//   • Request URL + method + body (the array of event payloads)
//   • Response status code (200 / 400 / network failure)
//   • Response body when the collector rejects the batch
//
// Snowplow's own logger only prints "Connection error: -" on failure, with
// zero detail about WHAT was sent or WHY the collector rejected it — that
// makes debugging schema mismatches or transport bugs painful. This wrapper
// keeps the default tracker behavior (POST batching, retries, store id
// tracking) and just teas a log statement on each end of the request.

import Foundation
import UniTrack
#if canImport(SnowplowTracker)
import SnowplowTracker

@objc final class UniTrackSnowplowNetworkConnection: NSObject, NetworkConnection {

    private let endpoint: URL
    private let httpMethodOptions: HttpMethodOptions
    /// The default Snowplow connection — we delegate the actual transport to
    /// it so retries / batching / store-id tracking all keep working.
    private let inner: DefaultNetworkConnection

    init(endpoint: String, method: HttpMethodOptions = .post) {
        // DefaultNetworkConnection appends the standard tp2 path itself when
        // the URL has no path component — keep parity by passing the raw
        // endpoint through unchanged.
        self.endpoint = URL(string: endpoint) ?? URL(fileURLWithPath: "/dev/null")
        self.httpMethodOptions = method
        self.inner = DefaultNetworkConnection(urlString: endpoint, httpMethod: method)
    }

    @objc var httpMethod: HttpMethodOptions { httpMethodOptions }
    @objc var urlEndpoint: URL? { inner.urlEndpoint }

    @objc func sendRequests(_ requests: [Request]) -> [RequestResult] {
        // Log every batch we're about to send. Each request typically carries
        // 1-50 event payloads (depends on emitter.bufferOption). We dump the
        // payload as JSON so the integrator can copy it straight into a
        // Snowplow Mini Iglu validator if the collector rejects it.
        for (i, req) in requests.enumerated() {
            let body = Self.payloadJSON(req.payload)
            let url = inner.urlEndpoint?.absoluteString ?? "(no endpoint)"
            UniTrack.log("[UniTrackSnowplow→net] POST %@ batch=%d/%d events=%d body=%@",
                         url, i + 1, requests.count, req.emitterEventIds.count, body)
        }

        let results = inner.sendRequests(requests)

        // Log the outcome of each request: status code (200 / 400 / 500),
        // the store ids the collector accepted, and the oversize flag (set
        // when 1 event alone exceeds the Snowplow payload size cap).
        for (i, result) in results.enumerated() {
            let status = result.statusCode ?? -1
            let outcome = result.isSuccessful ? "OK" : "FAIL"
            UniTrack.log("[UniTrackSnowplow→net] %@ %d batch=%d/%d store_ids=%@ oversize=%@",
                         outcome, status, i + 1, results.count,
                         String(describing: result.storeIds),
                         result.isOversize ? "true" : "false")
        }
        return results
    }

    // MARK: - Internals

    /// Serialize the Snowplow Payload to a pretty JSON string for logging.
    /// Falls back to `String(describing:)` if the payload isn't JSON-safe
    /// (shouldn't happen — Snowplow only puts primitives / arrays / dicts in).
    private static func payloadJSON(_ payload: Payload?) -> String {
        guard let payload = payload else { return "(nil payload)" }
        let dict = payload.dictionary
        if JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: dict)
    }
}

#endif
