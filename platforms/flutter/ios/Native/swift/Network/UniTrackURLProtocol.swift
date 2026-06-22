// UniTrackURLProtocol.swift
//
// Intercepts URL requests system-wide. Tracks: url, method, status,
// duration, request/response body sizes, error.
//
// Privacy: only the host+path is logged by default. Query strings,
// request bodies, response bodies, and `Authorization` headers are
// stripped. Override `shouldRedact(_:)` for partner-specific rules.

import Foundation

final class UniTrackURLProtocol: URLProtocol, URLSessionDataDelegate {

    static let handledKey = "UniTrackURLProtocolHandled"

    // URLs whose absolute string contains any of these substrings are NOT
    // captured. This stops a feedback loop: the SDK's own uploads (portal
    // ingest endpoint, Snowplow collector, provider mirror) would otherwise be
    // auto-captured as network_request, forwarded again, captured again, …
    // Populated by UniTrack at init via `excludeURL(containing:)`.
    private static let ignoredLock = NSLock()
    private static var ignoredSubstrings: [String] = []

    static func excludeURL(containing substring: String) {
        guard !substring.isEmpty else { return }
        ignoredLock.lock(); defer { ignoredLock.unlock() }
        if !ignoredSubstrings.contains(substring) { ignoredSubstrings.append(substring) }
    }

    // ── W3C trace injection (slide 03 L1 — backend HTTP+trace header) ──
    //
    // Stored statically because (a) URLProtocol instances are created by the
    // URL Loading System, we don't own ctor params, and (b) the same setting
    // must apply to every intercepted request. Lock around mutation; readers
    // copy out under lock so the hot path doesn't hold it across the fetch.
    private static let traceLock = NSLock()
    private static var traceEnabled = false
    private static var traceHeader  = "traceparent"
    private static var traceAllow:  [String] = []
    private static var traceSampled = true

    static func configureTracing(enabled: Bool,
                                 headerName: String,
                                 allowlistHosts: [String],
                                 sampled: Bool) {
        traceLock.lock(); defer { traceLock.unlock() }
        traceEnabled = enabled
        traceHeader  = headerName.isEmpty ? "traceparent" : headerName
        traceAllow   = allowlistHosts
        traceSampled = sampled
    }

    private static func tracingSnapshot() -> (Bool, String, [String], Bool) {
        traceLock.lock(); defer { traceLock.unlock() }
        return (traceEnabled, traceHeader, traceAllow, traceSampled)
    }

    private static func isIgnored(_ url: URL?) -> Bool {
        guard let s = url?.absoluteString else { return false }
        ignoredLock.lock(); defer { ignoredLock.unlock() }
        return ignoredSubstrings.contains { !$0.isEmpty && s.contains($0) }
    }

    private var session: URLSession?
    // Renamed from `task` to avoid illegally overriding URLProtocol.task.
    private var dataTask: URLSessionDataTask?
    private var startAt: Date = Date()
    private var responseBytes: Int = 0
    // Trace ids minted in startLoading() so the same ids appear on the wire
    // header AND in the network_request event we log on completion.
    private var traceIds: UniTrackTraceIds?

    static func install() {
        URLProtocol.registerClass(UniTrackURLProtocol.self)
        // Insert into default URLSessionConfiguration too — required to
        // intercept sessions created via `URLSession(configuration:)`.
        swizzleDefaultSessionConfiguration()
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }
        // Never capture the SDK's own analytics uploads (avoids a feedback loop).
        if isIgnored(request.url) { return false }
        return request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

    override func startLoading() {
        startAt = Date()
        let mreq = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mreq)

        // Inject W3C `traceparent` if tracing is on AND the request's host is
        // on the allowlist. Skip if the app already set the header (manual
        // propagation wins — don't clobber an explicit upstream trace).
        let (enabled, hdrName, allow, sampled) = Self.tracingSnapshot()
        if enabled,
           UniTrackTracing.shouldInject(host: request.url?.host, allowlist: allow),
           mreq.value(forHTTPHeaderField: hdrName) == nil {
            let ids = UniTrackTracing.newTrace()
            mreq.setValue(UniTrackTracing.traceparent(ids, sampled: sampled),
                          forHTTPHeaderField: hdrName)
            traceIds = ids
        }

        let cfg = URLSessionConfiguration.default
        cfg.protocolClasses = (cfg.protocolClasses ?? []).filter {
            $0 != UniTrackURLProtocol.self
        }
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        dataTask = session?.dataTask(with: mreq as URLRequest)
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response,
                            cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        responseBytes += data.count
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let durationMs = Int(Date().timeIntervalSince(startAt) * 1000)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let url    = redacted(request.url)
        let method = request.httpMethod ?? "GET"
        let reqBytes = Int(request.httpBody?.count ?? 0)

        var props: [String: Any] = [
            "url":         url,
            "method":      method,
            "status":      status,
            "duration_ms": durationMs,
            "req_bytes":   reqBytes,
            "resp_bytes":  responseBytes,
            "error":       error?.localizedDescription ?? ""
        ]
        // Carry trace_id/span_id on the event so the portal can render a "copy
        // trace_id → grep backend logs" affordance per request.
        if let ids = traceIds {
            props["trace_id"] = ids.traceId
            props["span_id"]  = ids.spanId
        }
        UniTrack.track("network_request", properties: props)

        if let err = error {
            client?.urlProtocol(self, didFailWithError: err)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func redacted(_ url: URL?) -> String {
        guard let u = url else { return "" }
        var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        comps?.query    = nil
        comps?.fragment = nil
        return comps?.url?.absoluteString ?? u.absoluteString
    }

    // Inject UniTrackURLProtocol into URLSessionConfiguration.default by
    // swizzling the class method `default`.
    private static func swizzleDefaultSessionConfiguration() {
        let cls: AnyClass = URLSessionConfiguration.self
        let sel1 = NSSelectorFromString("defaultSessionConfiguration")
        let sel2 = #selector(URLSessionConfiguration.ut_defaultSessionConfiguration)
        guard let m1 = class_getClassMethod(cls, sel1),
              let m2 = class_getClassMethod(cls, sel2) else { return }
        method_exchangeImplementations(m1, m2)
    }
}

extension URLSessionConfiguration {
    @objc class func ut_defaultSessionConfiguration() -> URLSessionConfiguration {
        let cfg = ut_defaultSessionConfiguration() // calls original
        var protos = cfg.protocolClasses ?? []
        if !protos.contains(where: { $0 == UniTrackURLProtocol.self }) {
            protos.insert(UniTrackURLProtocol.self, at: 0)
            cfg.protocolClasses = protos
        }
        return cfg
    }
}
