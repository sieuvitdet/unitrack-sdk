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
        // Body of every batch was logged here previously — useful for
        // first-time wiring, noise after that (the same JSON is already in
        // the "─── Snowplow Tracking ───" envelope UniTrack logs at the
        // convention layer). Keep only the wire outcome so 400/-1 failures
        // still surface immediately.
        let results = inner.sendRequests(requests)

        for (i, result) in results.enumerated() {
            let status = result.statusCode ?? -1
            let outcome = result.isSuccessful ? "OK" : "FAIL"
            UniTrack.log("[UniTrackSnowplow→net] %@ %d batch=%d/%d events=%d",
                         outcome, status, i + 1, results.count,
                         requests.indices.contains(i) ? requests[i].emitterEventIds.count : 0)
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
