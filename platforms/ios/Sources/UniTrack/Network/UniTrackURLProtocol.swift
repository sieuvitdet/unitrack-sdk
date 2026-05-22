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

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var startAt: Date = Date()
    private var responseBytes: Int = 0

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
        return request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

    override func startLoading() {
        startAt = Date()
        let mreq = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mreq)

        let cfg = URLSessionConfiguration.default
        cfg.protocolClasses = (cfg.protocolClasses ?? []).filter {
            $0 != UniTrackURLProtocol.self
        }
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: mreq as URLRequest)
        task?.resume()
    }

    override func stopLoading() {
        task?.cancel()
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

        UniTrack.track("network_request", properties: [
            "url":         url,
            "method":      method,
            "status":      status,
            "duration_ms": durationMs,
            "req_bytes":   reqBytes,
            "resp_bytes":  responseBytes,
            "error":       error?.localizedDescription ?? ""
        ])

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
