// ManualTrackSignal.swift
//
// Heuristic dedup giữa MANUAL tracking (DEV gọi Firebase.logEvent /
// Snowplow.track / UniTrack.track trong handler) và AUTO-capture (swizzler
// tap/screen/network). Khi cả 2 fire trong cùng một user gesture window,
// SDK giữ manual + bỏ auto.
//
// Lý do tồn tại file này: khách bật trackTaps=true trên Portal vì muốn
// auto-capture cho 90% button "anonymous"; nhưng 3 button quan trọng đã
// có manual tracking từ trước → portal nhận trùng event. Operator không
// muốn tắt cờ global (mất 90% còn lại) cũng không muốn DEV đi xoá manual
// (legacy code). SDK tự arbitrate.
//
// Cơ chế:
//   1. Mỗi entry-point provider biết được (Firebase logEvent, Snowplow
//      Tracker.track, UniTrack.track) gọi recordManual(kind:).
//   2. Swizzler tap/screen/network trước khi emit auto-event gọi
//      shouldSuppress(kind:) — nếu có signal manual trong window thì skip.
//
// Window 200ms (tap + screen) / 500ms (network — network có async delay).
// Ring buffer 32 slot, đủ cho mọi burst thực tế. Không dùng dict per-view
// vì swizzler tap không trace ngược được view → handler binding ở phase
// fire action; bind theo time-only là đủ chính xác trong thực tế (1 user
// gesture không fire >1 event trong 200ms ở 99% case).

import Foundation

public enum ManualTrackKind: Int {
    case click          = 0  // tap, button, gesture
    case screen         = 1  // screen_view / screen_viewed
    case networkRequest = 2  // outbound HTTP
}

enum ManualTrackSignal {

    // Lock-free read on hot path (swizzler check) — readers copy out under
    // lock, then compare without holding it. Writers (provider hooks) are
    // rare enough vs readers (every tap/screen/request) that 1 lock is fine.
    private static let lock = NSLock()
    private static var slots: [(kind: ManualTrackKind, at: TimeInterval)] = []
    private static let cap = 32

    /// Default suppress window. Network gets a longer window because async
    /// handlers (URLSession callback → DEV log) can be 200-400ms behind the
    /// network start the swizzler intercepted. 200ms covers a typical sync
    /// onTap → logEvent stack.
    private static let clickWindowSec:   TimeInterval = 0.20
    private static let screenWindowSec:  TimeInterval = 0.20
    private static let networkWindowSec: TimeInterval = 0.50

    /// Provider hooks ghi signal khi DEV gọi manual tracking. Idempotent
    /// — ghi nhiều lần cùng kind trong burst window đè lên slot mới hơn,
    /// không tạo "queue" dài (suppress chỉ cần 1 signal bất kỳ).
    public static func recordManual(_ kind: ManualTrackKind) {
        let now = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        slots.append((kind, now))
        if slots.count > cap { slots.removeFirst(slots.count - cap) }
    }

    /// Swizzlers call this BEFORE emitting auto-event. Returns true if a
    /// matching manual signal exists in the suppress window — caller skips.
    public static func shouldSuppress(_ kind: ManualTrackKind) -> Bool {
        let now    = Date().timeIntervalSince1970
        let window: TimeInterval
        switch kind {
        case .click:          window = clickWindowSec
        case .screen:         window = screenWindowSec
        case .networkRequest: window = networkWindowSec
        }
        let cutoff = now - window
        lock.lock(); defer { lock.unlock() }
        // Hot path: vẫn O(n) nhưng n ≤ 32, cheaper than dict alloc.
        for s in slots.reversed() {
            if s.at < cutoff { break }   // slots in append order, mới nhất ở cuối
            if s.kind == kind { return true }
        }
        return false
    }

    /// Master toggle. Default ON. App can flip via UniTrack.setManualArbitration(false)
    /// nếu muốn cả manual lẫn auto fire (legacy compat). Read on every
    /// shouldSuppress() call so toggle takes effect instantly.
    private static var enabledFlag: Bool = true

    public static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabledFlag }
        set { lock.lock(); defer { lock.unlock() }; enabledFlag = newValue }
    }

    /// Convenience: returns shouldSuppress AND respects master toggle.
    static func shouldSkip(_ kind: ManualTrackKind) -> Bool {
        guard enabled else { return false }
        return shouldSuppress(kind)
    }
}
