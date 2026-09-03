// AppLifecycleObserver.swift
// Maps UIApplication foreground/background events to SDK events + handles
// the session_end + session_start pair when the app comes back from
// background. Parity with Android (ProcessLifecycleOwner) + Flutter
// (WidgetsBindingObserver).

import UIKit
// CACurrentMediaTime — đồng hồ đơn điệu cho các bộ đếm dwell.
import QuartzCore

enum AppLifecycleObserver {
    // Timestamp app đi bg (fg→bg). Nil khi app đang fg. Dùng để tính
    // background_sec per-screen mỗi lần bg→fg trong khi 1 screen còn active.
    /// Mốc vào background — WALL CLOCK, cố ý. Dòng emitSessionBoundariesIfNeeded
    /// so nó với sessionTimeoutMs, mà core C++ cũng quyết định rotate bằng wall
    /// clock (session_manager.cpp:236 — last_activity_ms_ phải sống sót qua lần
    /// app bị kill nên không thể dùng đồng hồ đơn điệu). Đổi riêng phía Swift
    /// sẽ làm hai tầng lệch pha: máy ngủ 35 phút thì mono không cộng khoảng
    /// ngủ, core đã rotate mà Swift vẫn tưởng phiên còn sống.
    private static var backgroundedAt: Date?
    /// Cùng mốc nhưng đo bằng đồng hồ đơn điệu, dùng cho bộ đếm background_sec.
    /// Tách khỏi backgroundedAt vì hai mục đích cần hai trục thời gian khác nhau.
    private static var backgroundedAtMono: CFTimeInterval?
    // Timestamp lần bg→fg gần nhất (hoặc cold-start). Dùng để tính
    // foreground_sec per-screen cho window fg đang mở.
    /// Mốc bắt đầu window foreground — đồng hồ đơn điệu. Chỉ dùng để cộng dồn
    /// foreground_sec, không so với timeout nào nên không có ràng buộc lệch pha.
    private static var lastForegroundedAt: CFTimeInterval?

    // ── Per-screen counters (match Snowplow screen_summary semantic) ──────
    // Snowplow builtin screen_summary/1-0-0 định nghĩa:
    //   foreground_sec = giây user active trên SCREEN NÀY (từ setScreen tới
    //                    lúc close screen). Reset per-screen.
    //   background_sec = giây SCREEN NÀY ở bg (app bg trong khi screen đang
    //                    active). Reset per-screen.
    // Roll-forward:
    //   • setScreen(newName)   → close screen cũ, reset counters cho screen mới
    //   • didEnterBackground   → +fg dwell hiện tại, ghi vào screenForegroundSec
    //   • didBecomeActive      → +bg dwell hiện tại, ghi vào screenBackgroundSec
    private static var screenForegroundSec: Int = 0
    private static var screenBackgroundSec: Int = 0

    /// Cumulative giây screen hiện tại đã ở bg. Đọc bởi setScreen() lúc
    /// close screen để stamp `background_sec` lên screen_exited.
    static func backgroundDwellSec() -> Int { screenBackgroundSec }

    /// Cumulative giây screen hiện tại đã ở fg. Bao gồm window fg đang mở.
    /// Đọc bởi setScreen() lúc close screen để stamp `foreground_sec` lên
    /// screen_exited (dùng thay cho dwell_ms — chính xác hơn khi có bg
    /// window ở giữa).
    static func foregroundDwellSec() -> Int {
        var total = screenForegroundSec
        if let fgAt = lastForegroundedAt {
            total += max(0, Int(CACurrentMediaTime() - fgAt))
        }
        return total
    }

    /// Called by UniTrack.setScreen() SAU khi đã stamp counters vào
    /// screen_exited payload. Reset để screen mới bắt đầu đếm lại từ 0.
    static func rollScreenCounters() {
        screenForegroundSec = 0
        screenBackgroundSec = 0
        lastForegroundedAt  = CACurrentMediaTime()  // screen mới bắt đầu window fg
    }

    // Snapshot of the session in progress at the moment we backgrounded —
    // used to populate session_ended fields (duration, screen_count, …) when
    // the foreground resolve confirms a rotation.
    private static var sessionAtBackground: SessionAtBackground?

    private struct SessionAtBackground {
        let id: String
        let startedAt: Date
        let screenCount: Int
        let hadError: Bool
        let hadCrash: Bool
    }

    static let installed: Void = {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { _ in
            let isResume = (backgroundedAt != nil)   // false on the very first launch
            // Roll bg window vừa completed vào per-screen counter.
            if let bgAtMono = backgroundedAtMono {
                screenBackgroundSec += max(0, Int(CACurrentMediaTime() - bgAtMono))
                backgroundedAtMono = nil
            }
            // backgroundedAt (wall) KHÔNG xoá ở đây — emitSessionBoundariesIfNeeded
            // đọc nó ngay sau đây để quyết định có vượt session timeout không.
            
            lastForegroundedAt = CACurrentMediaTime()
            UniTrack.track("app_foreground", properties: [:])
            // Re-fire screen_viewed for the top VC on resume. UIKit doesn't
            // re-call viewDidAppear when the app comes back to foreground —
            // the swizzler stays silent — but product spec says "Màn hình trở
            // thành foreground" counts as a screen_viewed. Guarded by isResume
            // so cold start (which already fired via viewDidAppear) doesn't
            // double-fire.
            if isResume, let current = UniTrack.previousScreenName(), !current.isEmpty {
                // didEnterBackground đã fire screen_exited cho chính screen
                // này → đây là boundary thật, phải fan-out screen_viewed lại.
                // Nhưng lastScreen vẫn giữ `current` nên dup guard sẽ nuốt.
                // reenterScreen() bypass guard đúng một lần và stamp
                // previous = current, để provider biết screen này vào lại từ
                // chính nó thay vì tự suy (Snowplow nếu tự suy sẽ ra
                // previousName = màn trước khi background — sai).
                // Chống-dup pop-popup không đổi: path đó không qua background.
                UniTrack.reenterScreen(current)
            }
            // Resolve the session — if background dwell exceeded the timeout,
            // the core rotates internally + we fire session_ended for the
            // closed session before session_started for the new one.
            emitSessionBoundariesIfNeeded()
            // Notify any host that registered onAppForeground — typically used
            // to refresh portal remote config so a user who just minimised the
            // app picks up new portal settings without killing + relaunching.
            // The fire is throttled (default 5 min) inside the SDK.
            UniTrack._fireForegroundIfThrottleElapsed()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { _ in
            // Roll fg window vừa closed vào per-screen counter.
            if let fgAt = lastForegroundedAt {
                screenForegroundSec += max(0, Int(CACurrentMediaTime() - fgAt))
                lastForegroundedAt = nil
            }
            // Fire screen_exited for the top VC BEFORE app_background so the
            // exit event carries the correct dwell + is ordered before the
            // lifecycle transition downstream. Product spec: "app bị pop /
            // exit" counts as screen_exited.
            if let current = UniTrack.previousScreenName(), !current.isEmpty {
                let endPayload: [String: Any] = [
                    "screen":         current,
                    "screen_name":    current,
                    // Per-screen semantics, matches Snowplow builtin
                    // screen_summary/1-0-0. String để parity Iglu schema
                    // (is_debug/is_rooted/... đã string).
                    "foreground_sec": String(screenForegroundSec),
                    "background_sec": String(screenBackgroundSec),
                    "is_exit_screen": "true",
                    "reason":         "app_backgrounded",
                ]
                UniTrack.track("screen_exited", properties: endPayload)
            }
            // ut_log_background() — NOT UniTrack.track("app_background").
            // The core fires app_background itself inside log_background()
            // and then calls session_.mark_clean_shutdown(), which persists
            // clean_shutdown=1. Tracking the event by hand skipped that flag,
            // so every cold start read clean_shutdown=false, diagnosed a kill
            // and rotated (session_manager.cpp:106 killed_recovered) — sessions
            // split 0.1s apart with a 30' timeout. Parity: Android
            // AppLifecycleObserver.kt calls NativeBridge.logBackground() here
            // and likewise does not track app_background itself.
            UniTrack._logBackgroundToCore()
            // Snapshot the session state so a later session_ended carries the
            // right duration + counters (the SDK doesn't track screen_count
            // itself yet — apps may pass their own via UniTrack.setSessionStat).
            backgroundedAt     = Date()              // cho phép so timeout
            backgroundedAtMono = CACurrentMediaTime() // cho bộ đếm background_sec
            sessionAtBackground = SessionAtBackground(
                id:          UniTrack.currentSessionId(),
                startedAt:   UniTrack.sessionStartedAt() ?? Date(),
                screenCount: UniTrack.sessionScreenCount(),
                hadError:    UniTrack.sessionHadError(),
                hadCrash:    UniTrack.sessionHadCrash()
            )
            UniTrack.flush()
        }
    }()

    /// Check whether the background dwell exceeded the session timeout and,
    /// if so, fire session_ended for the closed session. Called from the
    /// didBecomeActive handler — guarded by a check on backgroundedAt so the
    /// very first foreground after launch doesn't emit a phantom session_end.
    private static func emitSessionBoundariesIfNeeded() {
        guard let bgAt = backgroundedAt, let prev = sessionAtBackground else {
            backgroundedAt = nil; sessionAtBackground = nil; return
        }
        let dwellMs = Int(Date().timeIntervalSince(bgAt) * 1000)
        let timeoutMs = UniTrack.sessionTimeoutMs()
        // If we crossed the timeout the core has already rotated by the time
        // any event resolves; emit session_ended for the closed snapshot so
        // analytics can compute duration without the app coding it.
        if dwellMs >= timeoutMs {
            let duration = Int(Date().timeIntervalSince(prev.startedAt))
            UniTrack.track("session_ended", properties: [
                "session_id":           prev.id,
                "session_duration_sec": duration,
                "screen_count":         prev.screenCount,
                "had_error":            prev.hadError,
                "had_crash":            prev.hadCrash,
                "reason":               "timeout",
                "background_sec":       dwellMs / 1000,
            ])
        }
        backgroundedAt = nil
        sessionAtBackground = nil
    }

    static func install() { _ = installed }
}
