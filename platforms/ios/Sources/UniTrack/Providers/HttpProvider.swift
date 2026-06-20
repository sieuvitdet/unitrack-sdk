// HttpProvider — generic HTTP analytics provider.
//
// Mục tiêu: gắn UniTrack lên Kibana / Elasticsearch / Logstash / OpenSearch /
// backend FPT nội bộ trong 5 dòng config — không cần code transport, retry,
// batch, offline. UniTrack lo hết qua `PendingQueue`.
//
//   UniTrack.addHttpProvider(
//       id: "kibana",
//       endpoint: URL(string: "https://kibana.fpt.vn/_bulk")!,
//       format: .elasticBulk,
//       headers: ["Authorization": "ApiKey ..."],
//       batchSize: 50)
//
// Behaviour:
//   - 2xx                   → .success
//   - 4xx (except 408/429)  → .drop    (schema sai — đừng loop)
//   - 5xx / 408 / 429       → .retry   (PendingQueue backoff exponential)
//   - network/timeout       → .retry
import Foundation

public enum PayloadFormat: Int {
    /// 1 event = 1 POST as a single JSON object. Simplest backends.
    case jsonSingle = 0
    /// Batched: NDJSON, 1 line per event.
    case jsonLines = 1
    /// Batched: a JSON array per POST.
    case jsonArray = 2
    /// Elasticsearch _bulk API: action line + doc line, NDJSON, trailing newline.
    case elasticBulk = 3
}

public final class HttpProvider: AnalyticsProvider {

    public let providerId: String

    private let endpoint: URL
    private let format: PayloadFormat
    private let headers: [String: String]
    private let batchSize: Int
    private let flushInterval: TimeInterval

    private let q = DispatchQueue(label: "ut.httpprovider", qos: .utility)
    private var pending: [[String: Any]] = []
    private var lastFlushAt: TimeInterval = 0
    private let session: URLSession

    public init(id: String,
                endpoint: URL,
                format: PayloadFormat = .jsonSingle,
                headers: [String: String] = [:],
                batchSize: Int = 50,
                flushInterval: TimeInterval = 30,
                connectTimeout: TimeInterval = 10,
                readTimeout: TimeInterval = 15) {
        self.providerId    = id
        self.endpoint      = endpoint
        self.format        = format
        self.headers       = headers
        self.batchSize     = batchSize
        self.flushInterval = flushInterval
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = readTimeout
        cfg.timeoutIntervalForResource = readTimeout + connectTimeout
        // Skip UniTrackURLProtocol so we don't recursively track our own POSTs.
        cfg.protocolClasses = (cfg.protocolClasses ?? []).filter {
            String(describing: $0) != "UniTrackURLProtocol"
        }
        self.session = URLSession(configuration: cfg)
    }

    public func initializeProvider() { /* no SDK to wake */ }

    public func track(_ name: String, _ properties: [String: Any]) {
        _ = send(name, properties)
    }

    public func setUser(_ userId: String?, _ traits: [String: Any]) { /* no-op */ }
    public func setScreen(_ name: String) { /* no-op */ }

    public func send(_ name: String, _ properties: [String: Any]) -> ProviderResult {
        let event = stamp(name: name, properties: properties)
        switch format {
        case .jsonSingle:
            return postSync(body: jsonData(event), contentType: "application/json")
        case .jsonLines, .jsonArray, .elasticBulk:
            return bufferAndMaybeFlush(event: event)
        }
    }

    /// Force a flush — exposed for tests / lifecycle.
    public func flush() -> ProviderResult { flushBatch() }

    private func stamp(name: String, properties: [String: Any]) -> [String: Any] {
        var o = properties
        o["event_name"]    = name
        o["session_id"]    = UniTrack.currentSessionId()
        o["session_index"] = UniTrack.sessionIndex()
        if o["timestamp"] == nil {
            o["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
        }
        return o
    }

    private func bufferAndMaybeFlush(event: [String: Any]) -> ProviderResult {
        var due = false
        q.sync {
            pending.append(event)
            let now = Date().timeIntervalSince1970
            if pending.count >= batchSize || (now - lastFlushAt) >= flushInterval {
                due = true
            }
        }
        return due ? flushBatch() : .success
    }

    private func flushBatch() -> ProviderResult {
        var batch: [[String: Any]] = []
        q.sync {
            let n = min(batchSize, pending.count)
            batch = Array(pending.prefix(n))
            pending.removeFirst(n)
            lastFlushAt = Date().timeIntervalSince1970
        }
        guard !batch.isEmpty else { return .success }

        let (body, contentType) = encode(batch: batch)
        let r = postSync(body: body, contentType: contentType)
        if r != .success {
            // Put events back so PendingQueue replays them; avoid double-buffering.
            q.sync { pending.insert(contentsOf: batch, at: 0) }
        }
        return r
    }

    private func encode(batch: [[String: Any]]) -> (Data, String) {
        switch format {
        case .jsonSingle:
            return (jsonData(batch.first ?? [:]), "application/json")
        case .jsonLines:
            let s = batch.map { String(data: jsonData($0), encoding: .utf8) ?? "{}" }
                .joined(separator: "\n") + "\n"
            return (Data(s.utf8), "application/x-ndjson")
        case .jsonArray:
            let arr = try? JSONSerialization.data(withJSONObject: batch)
            return (arr ?? Data("[]".utf8), "application/json")
        case .elasticBulk:
            var s = ""
            for e in batch {
                s += "{\"index\":{}}\n"
                s += (String(data: jsonData(e), encoding: .utf8) ?? "{}") + "\n"
            }
            return (Data(s.utf8), "application/x-ndjson")
        }
    }

    private func jsonData(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    }

    private func postSync(body: Data, contentType: String) -> ProviderResult {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var result: ProviderResult = .retry
        let task = session.dataTask(with: req) { _, resp, err in
            defer { sem.signal() }
            if let e = err {
                NSLog("[UniTrack] HttpProvider %@ network error: %@ → RETRY",
                      self.providerId, e.localizedDescription)
                result = .retry
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200...299:                   result = .success
            case 408, 429, 500...599:         result = .retry
            case 400...499:
                NSLog("[UniTrack] HttpProvider %@ 4xx (%d) → DROP",
                      self.providerId, code)
                result = .drop
            default:                          result = .retry
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 30)
        return result
    }
}
