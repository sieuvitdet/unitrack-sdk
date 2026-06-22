// PendingQueue — per-provider ack offline queue, binding-side mirror of the
// Android PendingQueue. Stores events with a bitmask of pending providers,
// retries with exponential backoff on RETRY, drops on DROP / max retries / TTL.
//
// Lives in the iOS binding because providers (Snowplow, Firebase, HttpProvider)
// live above the C ABI — the C++ core's OfflineQueue only knows about Portal
// HTTP. Snowplow / Firebase SDKs already have their own retry queues; the
// PendingQueue exists so custom HttpProvider (Kibana / ELK / FPT internal)
// gets industry-grade offline retry for free without app code.
//
// Storage: a single JSON file at <library>/unitrack/pending.json, rewritten
// on every state change. Cap 20_000 events / 7 days / 10 MB approx — matches
// Android PendingQueue.
import Foundation

internal final class PendingQueue {

    static let shared = PendingQueue()

    private let mu = NSLock()
    private var rows: [Row] = []
    private var slots: [String: Int] = [:]   // provider_id → bit
    private var nextBit = 0
    private var nextRowId: Int64 = 1
    private let storeURL: URL

    private static let maxRetries = 10
    private static let maxEvents  = 20_000
    private static let ttlSeconds: TimeInterval = 7 * 24 * 3600
    private static let backoffBaseMs = 1_000
    private static let backoffMaxMs  = 300_000

    private init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("unitrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = base.appendingPathComponent("pending.json")
        load()
    }

    struct Row: Codable {
        var rowId: Int64
        var name: String
        var propsJson: String
        var pendingMask: Int64
        var retryCount: Int
        var nextRetryAtMs: Int64
        var createdAtMs: Int64
    }

    func bitFor(_ providerId: String) -> Int {
        mu.lock(); defer { mu.unlock() }
        if let b = slots[providerId] { return b }
        let b = nextBit
        nextBit += 1
        if b >= 63 {
            NSLog("[UniTrack] PendingQueue: provider slot overflow (\(providerId))")
        }
        slots[providerId] = b
        persistLocked()
        return b
    }

    /// Enqueue an event with pending delivery to `providerIds`.
    func enqueue(name: String, properties: [String: Any], providerIds: [String]) {
        guard !providerIds.isEmpty else { return }
        var mask: Int64 = 0
        for pid in providerIds { mask |= (Int64(1) << bitFor(pid)) }
        let json = jsonString(from: properties)
        mu.lock()
        let r = Row(
            rowId: nextRowId, name: name, propsJson: json,
            pendingMask: mask, retryCount: 0, nextRetryAtMs: 0,
            createdAtMs: nowMs()
        )
        nextRowId += 1
        rows.append(r)
        persistLocked()
        mu.unlock()
    }

    /// Peek events whose `next_retry_at` <= now, up to `max`.
    func peek(max: Int) -> [Row] {
        mu.lock(); defer { mu.unlock() }
        let now = nowMs()
        return rows.filter { $0.nextRetryAtMs <= now }.prefix(max).map { $0 }
    }

    /// Ack a delivery attempt.
    func ack(rowId: Int64,
             successful: [String], retrying: [String], dropped: [String]) {
        mu.lock(); defer { mu.unlock() }
        guard let idx = rows.firstIndex(where: { $0.rowId == rowId }) else { return }
        var r = rows[idx]
        for pid in successful { r.pendingMask &= ~(Int64(1) << slots[pid, default: 0]) }
        for pid in dropped    { r.pendingMask &= ~(Int64(1) << slots[pid, default: 0]) }
        // retrying bits stay set
        if r.pendingMask == 0 {
            rows.remove(at: idx)
            persistLocked()
            return
        }
        r.retryCount += 1
        if r.retryCount >= Self.maxRetries {
            NSLog("[UniTrack] PendingQueue: drop after \(r.retryCount) retries row=\(r.rowId)")
            rows.remove(at: idx)
            persistLocked()
            return
        }
        r.nextRetryAtMs = nowMs() + backoffMs(retry: r.retryCount)
        rows[idx] = r
        persistLocked()
    }

    func count() -> Int { mu.lock(); defer { mu.unlock() }; return rows.count }

    /// TTL + size cap. Call periodically.
    func trim() {
        mu.lock(); defer { mu.unlock() }
        let cutoff = nowMs() - Int64(Self.ttlSeconds * 1000)
        rows.removeAll { $0.createdAtMs < cutoff }
        if rows.count > Self.maxEvents {
            rows.removeFirst(rows.count - Self.maxEvents)
        }
        persistLocked()
    }

    /// Parsed properties of a Row (helper for the worker).
    func decodeProps(_ r: Row) -> [String: Any] {
        guard let d = r.propsJson.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [:] }
        return o
    }

    // MARK: - persistence

    private struct Snapshot: Codable {
        var rows: [Row]
        var slots: [String: Int]
        var nextBit: Int
        var nextRowId: Int64
    }

    private func load() {
        guard let d = try? Data(contentsOf: storeURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d)
        else { return }
        rows      = s.rows
        slots     = s.slots
        nextBit   = s.nextBit
        nextRowId = s.nextRowId
    }

    private func persistLocked() {
        let s = Snapshot(rows: rows, slots: slots, nextBit: nextBit, nextRowId: nextRowId)
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: storeURL, options: .atomic)
    }

    // MARK: - helpers

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func backoffMs(retry: Int) -> Int64 {
        let base = Int64(Double(Self.backoffBaseMs) * pow(2.0, Double(retry - 1)))
        let capped = min(base, Int64(Self.backoffMaxMs))
        let jitter = Int64(Double(capped) * (Double.random(in: 0...1) * 0.4 - 0.2))
        return capped + jitter
    }

    private func jsonString(from m: [String: Any]) -> String {
        let normalized = m.mapValues { $0 is NSNull ? NSNull() : $0 }
        guard let d = try? JSONSerialization.data(withJSONObject: normalized) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}
