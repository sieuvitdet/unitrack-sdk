// DemoAPI — fires realistic backend calls so the UniTrack SDK auto-captures
// them as `network_request` events. Used to make the session tree / wireframe
// richer: each user action triggers one or more API calls with varied status
// codes (200/4xx/5xx) so the per-session wireframe shows success vs error.
//
// httpbin.org lets us request a specific status via /status/<code>, and echo a
// path via /anything/<path> — handy for distinct, readable URLs in the tree.

import Foundation

enum DemoAPI {
    /// GET a backend "resource" path; status defaults to 200. The SDK's
    /// URLProtocol captures method/host/path/status/duration automatically.
    static func call(_ path: String, method: String = "GET", status: Int = 200) {
        // /status/<code> returns that HTTP status; we tack the logical path on as
        // a query so the captured URL is self-describing in the wireframe.
        guard let url = URL(string: "https://httpbin.org/status/\(status)?path=\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Fire several calls in sequence with small delays so they read as a flow.
    static func sequence(_ calls: [(path: String, method: String, status: Int)]) {
        for (i, c) in calls.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) {
                call(c.path, method: c.method, status: c.status)
            }
        }
    }
}
