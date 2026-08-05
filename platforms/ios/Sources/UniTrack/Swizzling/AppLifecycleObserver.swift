// AppLifecycleObserver.swift
// Maps UIApplication foreground/background events to SDK events + handles
// the session_end + session_start pair when the app comes back from
// background. Parity with Android (ProcessLifecycleOwner) + Flutter
// (WidgetsBindingObserver).

import UIKit

enum AppLifecycleObserver {
    // Track when the app went to background so foreground can compute the
    // background dwell + decide whether the previous session timed out.
    private static var backgroundedAt: Date?
    // Last background→foreground transition timestamp — used to stamp
    // `background_sec` on `screen_exited` events so consumers can tell
    // "user exited via bg" from "user just tapped another screen".
    private static var lastForegroundedAt: Date?
    // Total seconds the app has spent in background since the last
    // foreground. Rolled over on didBecomeActive.
    private static var lastBackgroundDwellSec: Int = 0

    /// Seconds the app spent in background between the previous foreground
    /// and the current one. 0 if the app never backgrounded since launch.
    /// Called by UniTrack.setScreen() to stamp `background_sec` on
    /// screen_exited events.
    static func backgroundDwellSec() -> Int { lastBackgroundDwellSec }
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
            // Freeze the dwell BEFORE clearing backgroundedAt so subsequent
            // screen_exited events can stamp background_sec.
            let isResume = (backgroundedAt != nil)   // false on the very first launch
            if let bgAt = backgroundedAt {
                lastBackgroundDwellSec = Int(Date().timeIntervalSince(bgAt))
            }
            lastForegroundedAt = Date()
            UniTrack.track("app_foreground", properties: [:])
            // Re-fire screen_viewed for the top VC on resume. UIKit doesn't
            // re-call viewDidAppear when the app comes back to foreground —
            // the swizzler stays silent — but product spec says "Màn hình trở
            // thành foreground" counts as a screen_viewed. Guarded by isResume
            // so cold start (which already fired via viewDidAppear) doesn't
            // double-fire.
            if isResume, let current = UniTrack.previousScreenName(), !current.isEmpty {
                UniTrack.setScreen(current)
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
            // Fire screen_exited for the top VC BEFORE app_background so the
            // exit event carries the correct dwell + is ordered before the
            // lifecycle transition downstream. Product spec: "app bị pop /
            // exit" counts as screen_exited.
            if let current = UniTrack.previousScreenName(), !current.isEmpty {
                // foreground_sec = giây ở foreground kể từ lần bg→fg gần nhất
                // (hoặc cold-start) tới lúc exit này. Downstream dùng để tính
                // engagement per-foreground-session, phân biệt với dwell_ms
                // của navigate-away.
                let fgSec: Int
                if let fgAt = lastForegroundedAt {
                    fgSec = Int(Date().timeIntervalSince(fgAt))
                } else {
                    fgSec = 0
                }
                let endPayload: [String: Any] = [
                    "screen":         current,
                    "screen_name":    current,
                    "foreground_sec": fgSec,
                    // background_sec = 0 vì đây là bg-EXIT event, chưa vào bg;
                    // chỉ set khi resume (screen_viewed sau bg→fg). Kept để
                    // schema field-list đồng nhất — consumer không phải null-check.
                    "background_sec": String(lastBackgroundDwellSec),
                    "is_exit_screen": "true",
                    "reason":         "app_backgrounded",
                ]
                UniTrack.track("screen_exited", properties: endPayload)
            }
            UniTrack.track("app_background", properties: [:])
            // Snapshot the session state so a later session_ended carries the
            // right duration + counters (the SDK doesn't track screen_count
            // itself yet — apps may pass their own via UniTrack.setSessionStat).
            backgroundedAt = Date()
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
