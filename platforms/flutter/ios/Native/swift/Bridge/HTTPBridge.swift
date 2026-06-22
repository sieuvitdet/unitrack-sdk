// HTTPBridge.swift
//
// Provides a C callback for the core's `ut_set_http_transport`. The core
// hands us URL, method, headers (JSON), and body — we POST via URLSession.

import Foundation
// See UniTrack.swift for why this import is guarded.
#if canImport(UniTrackCore)
import UniTrackCore
#endif

private struct HTTPSender {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // We must NOT include UniTrackURLProtocol here, or we'd recurse
        // forever (the SDK would track its own egress).
        cfg.protocolClasses = (cfg.protocolClasses ?? []).filter {
            $0 != UniTrackURLProtocol.self
        }
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()
}

enum HTTPBridge {
    static func install(into ctx: OpaquePointer) {
        let cb: ut_http_send_fn = { urlC, methodC, headersC, bodyC, bodyLen, _ in
            guard let urlC = urlC, let methodC = methodC, let bodyC = bodyC else {
                return -1
            }
            guard let url = URL(string: String(cString: urlC)) else {
                return -2
            }
            var req = URLRequest(url: url)
            req.httpMethod = String(cString: methodC)
            req.httpBody = Data(bytes: bodyC, count: bodyLen)

            if let hC = headersC,
               let hdrs = try? JSONSerialization.jsonObject(
                    with: Data(String(cString: hC).utf8)) as? [String: String] {
                for (k, v) in hdrs { req.setValue(v, forHTTPHeaderField: k) }
            }
            req.setValue("\(bodyLen)", forHTTPHeaderField: "Content-Length")

            // Synchronous via semaphore — core flush thread blocks here briefly.
            let sem = DispatchSemaphore(value: 0)
            var status: Int32 = 0
            HTTPSender.session.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse {
                    status = Int32(http.statusCode)
                }
                sem.signal()
            }.resume()
            sem.wait()
            return status
        }
        ut_set_http_transport(ctx, cb, nil)
    }
}
