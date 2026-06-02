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
            inForeground = true
            NativeBridge.logForeground()
            UniTrack.dispatchForegroundCallback()
        }
        started++
    }

    override fun onActivityStopped(a: Activity) {
        started = (started - 1).coerceAtLeast(0)
        if (started == 0 && inForeground) {
            inForeground = false
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
