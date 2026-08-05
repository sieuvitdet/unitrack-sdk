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

    // ── Per-screen counters (match Snowplow screen_summary semantic) ───────
    // foreground_sec = giây user active trên SCREEN NÀY (từ setScreen tới
    //                  lúc close screen). Reset per-screen.
    // background_sec = giây SCREEN NÀY ở bg (app bg trong khi screen đang
    //                  active). Reset per-screen.
    // Roll-forward:
    //   • setScreen(newName)   → close screen cũ, rollScreenCounters() cho screen mới
    //   • onActivityStopped    → +fg dwell hiện tại vào screenForegroundSec
    //   • onActivityStarted    → +bg dwell hiện tại vào screenBackgroundSec
    @Volatile private var screenForegroundSec: Int = 0
    @Volatile private var screenBackgroundSec: Int = 0

    /** Cumulative giây screen hiện tại đã ở bg. Đọc bởi setScreen(). */
    fun backgroundDwellSec(): Int = screenBackgroundSec

    /** Cumulative giây screen hiện tại đã ở fg. Bao gồm window fg đang mở. */
    fun foregroundDwellSec(): Int {
        var total = screenForegroundSec
        if (lastForegroundedAtMs > 0L) {
            total += ((System.currentTimeMillis() - lastForegroundedAtMs) / 1000L).toInt()
        }
        return total
    }

    /** Called by UniTrack.setScreen() sau khi đã stamp counters vào
     *  screen_exited payload. Reset để screen mới đếm lại từ 0. */
    fun rollScreenCounters() {
        screenForegroundSec = 0
        screenBackgroundSec = 0
        lastForegroundedAtMs = System.currentTimeMillis()
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
            // Roll bg window vừa completed vào per-screen counter.
            if (backgroundedAtMs > 0L) {
                screenBackgroundSec += ((System.currentTimeMillis() - backgroundedAtMs) / 1000L).toInt()
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
            // Roll fg window vừa closed vào per-screen counter BEFORE stamping.
            if (lastForegroundedAtMs > 0L) {
                screenForegroundSec += ((System.currentTimeMillis() - lastForegroundedAtMs) / 1000L).toInt()
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
                    // Per-screen semantics — match Snowplow screen_summary/1-0-0.
                    // String parity Iglu schema.
                    "foreground_sec" to screenForegroundSec.toString(),
                    "background_sec" to screenBackgroundSec.toString(),
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
