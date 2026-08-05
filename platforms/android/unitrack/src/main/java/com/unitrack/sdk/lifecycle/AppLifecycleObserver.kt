package com.unitrack.sdk.lifecycle

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.os.Bundle
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.bridge.NativeBridge

/**
 * Tracks app foreground / background transitions and forwards memory
 * pressure signals to the core.
 *
 * Uses ProcessLifecycleOwner-equivalent logic without a hard dependency
 * on androidx.lifecycle: counts started activities, fires foreground
 * when the count goes 0 → 1 and background when 1 → 0.
 */
internal object AppLifecycleObserver : Application.ActivityLifecycleCallbacks,
                                       ComponentCallbacks2 {

    private var started = 0
    @Volatile private var inForeground = false
    // Timestamp of the last 1→0 transition (going background). Cleared
    // when we come back foreground so `backgroundDwellSec` reports the
    // MOST RECENT bg→fg gap, not a running total.
    @Volatile private var backgroundedAtMs: Long = 0L
    // Timestamp of the most recent 0→1 foreground transition (or cold start).
    // 0 until the first foreground.
    @Volatile private var lastForegroundedAtMs: Long = 0L
    // Cumulative seconds spent in bg / fg WITHIN THE CURRENT SESSION. Reset
    // on session rotation via resetSessionCountersIfNeeded(). Bg counter
    // rolled forward on bg→fg, fg counter rolled forward on fg→bg.
    @Volatile private var sessionBackgroundSec: Int = 0
    @Volatile private var sessionForegroundSec: Int = 0
    // The session_id these counters were opened against. When the current
    // session_id changes (rotation), we reset before stamping so counters
    // never leak across sessions.
    @Volatile private var countersOpenedForSession: String = ""

    fun backgroundDwellSec(): Int {
        resetSessionCountersIfNeeded()
        return sessionBackgroundSec
    }

    private fun resetSessionCountersIfNeeded() {
        val sid = UniTrack.currentSessionId()
        if (sid != countersOpenedForSession) {
            sessionBackgroundSec = 0
            sessionForegroundSec = 0
            countersOpenedForSession = sid
        }
    }

    fun install(app: Application) {
        app.registerActivityLifecycleCallbacks(this)
        app.registerComponentCallbacks(this)
        // The SDK is often initialized AFTER the first activity has already
        // started (Application.onCreate → SDK init → MainActivity.onCreate is
        // typical, but async config fetch flips it). Without seeding `started`
        // from the current activity stack, the next onActivityStopped would
        // wrap to -1, foreground/background transitions wouldn't fire, and
        // app-side listeners would never see the background event.
        seedStartedFromAlreadyResumedActivities()
    }

    @Suppress("PrivateApi", "DiscouragedPrivateApi")
    private fun seedStartedFromAlreadyResumedActivities() {
        try {
            val tCls = Class.forName("android.app.ActivityThread")
            val tInstance = tCls.getMethod("currentActivityThread").invoke(null)
            val map = tCls.getDeclaredField("mActivities").apply { isAccessible = true }.get(tInstance) as Map<*, *>
            var n = 0
            for (record in map.values) {
                val rec = record ?: continue
                val paused = rec.javaClass.getDeclaredField("paused").apply { isAccessible = true }.getBoolean(rec)
                val stopped = try { rec.javaClass.getDeclaredField("stopped").apply { isAccessible = true }.getBoolean(rec) } catch (_: Throwable) { false }
                if (!paused && !stopped) n++
            }
            if (n > 0) {
                started = n
                inForeground = true
            }
        } catch (_: Throwable) { /* reflection blocked → live with the lifecycle as observed */ }
    }

    override fun onActivityStarted(a: Activity) {
        if (started == 0 && !inForeground) {
            val isResume = backgroundedAtMs > 0L   // false on very first launch
            inForeground = true
            // Add the bg dwell we just completed to the session's cumulative
            // total BEFORE clearing backgroundedAtMs.
            resetSessionCountersIfNeeded()
            if (backgroundedAtMs > 0L) {
                sessionBackgroundSec += ((System.currentTimeMillis() - backgroundedAtMs) / 1000L).toInt()
                backgroundedAtMs = 0L
            }
            lastForegroundedAtMs = System.currentTimeMillis()
            NativeBridge.logForeground()
            // Re-fire screen_viewed for the top Activity on resume. Android
            // doesn't automatically re-call onResume when the process comes
            // back to foreground for THIS purpose (well it does re-call
            // onResume, but auto-capture only wires setScreen from onCreate);
            // product spec (FLI) says "Màn hình trở thành foreground" counts
            // as screen_viewed. Guarded by isResume so cold start (which
            // already fired via the Activity swizzler) doesn't double-fire.
            if (isResume) {
                val current = UniTrack.previousScreenName()
                if (!current.isNullOrEmpty()) UniTrack.setScreen(current)
            }
            UniTrack.dispatchForegroundCallback()
        }
        started++
    }

    override fun onActivityStopped(a: Activity) {
        started = (started - 1).coerceAtLeast(0)
        if (started == 0 && inForeground) {
            inForeground = false
            // Roll the fg window we just closed into the session's cumulative
            // total BEFORE stamping / firing anything downstream.
            resetSessionCountersIfNeeded()
            if (lastForegroundedAtMs > 0L) {
                sessionForegroundSec += ((System.currentTimeMillis() - lastForegroundedAtMs) / 1000L).toInt()
                lastForegroundedAtMs = 0L
            }
            // Fire screen_exited for the top Activity BEFORE app_background so
            // the exit event is ordered before the lifecycle transition
            // downstream. Product spec: "app bị pop / exit" counts as
            // screen_exited.
            val current = UniTrack.previousScreenName()
            if (!current.isNullOrEmpty()) {
                UniTrack.track("screen_exited", mapOf(
                    "screen"         to current,
                    "screen_name"    to current,
                    // Cumulative per-session. background_sec = tổng giây app
                    // đã ở bg trong session hiện tại (chưa tính lần bg đang
                    // chuẩn bị bắt đầu). foreground_sec = tổng giây app đã ở
                    // fg trong session. String parity Iglu schema.
                    "foreground_sec" to sessionForegroundSec.toString(),
                    "background_sec" to sessionBackgroundSec.toString(),
                    "is_exit_screen" to "true",
                    "reason"         to "app_backgrounded",
                ))
            }
            backgroundedAtMs = System.currentTimeMillis()
            NativeBridge.logBackground()
            UniTrack.dispatchBackgroundCallback()
        }
    }

    // ─── unused activity callbacks ────────────────────────────────────────
    override fun onActivityCreated(a: Activity, b: Bundle?) {}
    override fun onActivityResumed(a: Activity) {}
    override fun onActivityPaused(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
    override fun onActivityDestroyed(a: Activity) {}

    // ─── memory pressure ──────────────────────────────────────────────────
    override fun onTrimMemory(level: Int) {
        // RUNNING_LOW, RUNNING_CRITICAL, COMPLETE are the signals that
        // typically precede an OOM kill.
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            val rt   = Runtime.getRuntime()
            val used = rt.totalMemory() - rt.freeMemory()
            NativeBridge.logMemoryWarning(used, rt.maxMemory(), "")
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {}

    @Deprecated("Deprecated in API 35")
    override fun onLowMemory() {
        val rt = Runtime.getRuntime()
        NativeBridge.logMemoryWarning(rt.totalMemory() - rt.freeMemory(),
                                       rt.maxMemory(), "")
    }
}
