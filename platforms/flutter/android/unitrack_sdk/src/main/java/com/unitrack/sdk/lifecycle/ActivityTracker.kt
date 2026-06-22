package com.unitrack.sdk.lifecycle

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import com.unitrack.sdk.UniTrack

/**
 * Auto-tracks Activity and Fragment screen views.
 * No partner code required — just install once at SDK init.
 */
internal object ActivityTracker : Application.ActivityLifecycleCallbacks {

    fun install(app: Application) {
        app.unregisterActivityLifecycleCallbacks(this) // idempotent
        app.registerActivityLifecycleCallbacks(this)
        // If an Activity is ALREADY resumed when we install (common when init
        // is async and finishes after the first onResume), no callback will
        // fire for it — emit setScreen for it now so the first screen isn't
        // lost, AND register fragment callbacks for it so subsequent fragment
        // transitions inside that activity are tracked.
        currentResumedActivity(app)?.let { a ->
            UniTrack.setScreen(resolveScreenName(a))
            if (a is FragmentActivity) {
                try {
                    a.supportFragmentManager.registerFragmentLifecycleCallbacks(fragmentCb, true)
                } catch (_: Throwable) { /* ignore */ }
            }
        }
    }

    @Suppress("PrivateApi", "DiscouragedPrivateApi")
    private fun currentResumedActivity(app: Application): Activity? = try {
        val tCls = Class.forName("android.app.ActivityThread")
        val tInstance = tCls.getMethod("currentActivityThread").invoke(null)
        val map = tCls.getDeclaredField("mActivities").apply { isAccessible = true }.get(tInstance) as Map<*, *>
        var found: Activity? = null
        for (record in map.values) {
            val rec = record ?: continue
            val pausedField = rec.javaClass.getDeclaredField("paused").apply { isAccessible = true }
            if (pausedField.getBoolean(rec)) continue
            val actField = rec.javaClass.getDeclaredField("activity").apply { isAccessible = true }
            found = actField.get(rec) as? Activity
            if (found != null) break
        }
        found
    } catch (_: Throwable) { null }

    override fun onActivityResumed(activity: Activity) {
        val name = resolveScreenName(activity)
        UniTrack.setScreen(name)

        if (activity is FragmentActivity) {
            try {
                activity.supportFragmentManager.registerFragmentLifecycleCallbacks(
                    fragmentCb, true)
            } catch (_: Throwable) { /* ignore */ }
        }
    }

    override fun onActivityPaused(activity: Activity) {
        if (activity is FragmentActivity) {
            try {
                activity.supportFragmentManager.unregisterFragmentLifecycleCallbacks(
                    fragmentCb)
            } catch (_: Throwable) { /* ignore */ }
        }
    }

    // No-ops for the rest.
    override fun onActivityCreated(a: Activity, b: Bundle?) {}
    override fun onActivityStarted(a: Activity) {}
    override fun onActivityStopped(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
    override fun onActivityDestroyed(a: Activity) {}

    private fun resolveScreenName(a: Activity): String {
        // Use the Activity's CLASS NAME as the stable screen name (mirrors the
        // iOS swizzler's ut_screenName). We intentionally do NOT use
        // activity.title — it's often a dynamic/display string (e.g. a camera
        // name or the app label) and not a stable analytics key.
        return a.javaClass.simpleName
    }

    // ─── Fragment tracking ────────────────────────────────────────────────
    // We stash the wall-clock at onFragmentCreated and measure load_ms at
    // onFragmentResumed (= "screen visible & interactive"). This mirrors iOS
    // ViewControllerSwizzler's viewDidLoad → viewDidAppear timing.
    private val createdAtMs = java.util.WeakHashMap<Fragment, Long>()

    private fun isNoiseFragmentName(name: String): Boolean =
        name.startsWith("Nav") || name == "ReportFragment" ||
        name == "ScreenStackFragment" || name == "ScreenFragment" ||
        name == "ScreenContainer" || name.startsWith("Supportable")

    private val fragmentCb = object : FragmentManager.FragmentLifecycleCallbacks() {
        override fun onFragmentCreated(fm: FragmentManager, f: Fragment, savedInstanceState: Bundle?) {
            if (isNoiseFragmentName(f.javaClass.simpleName)) return
            createdAtMs[f] = android.os.SystemClock.elapsedRealtime()
        }

        override fun onFragmentResumed(fm: FragmentManager, f: Fragment) {
            val name = f.javaClass.simpleName
            if (isNoiseFragmentName(name)) return
            UniTrack.setScreen(name)

            // Fire screen_load_completed with the create → resume delta. The
            // event name + auto-fire mirror the iOS swizzler so the wire shape
            // is the same on both platforms. Cleared after fire so a re-entry
            // (back-stack pop) gets a fresh load_ms next time onFragmentCreated
            // runs.
            val createdAt = createdAtMs.remove(f) ?: return
            val loadMs = (android.os.SystemClock.elapsedRealtime() - createdAt).toInt()
            UniTrack.track(UniTrack.screenLoadEventName, mapOf(
                "screen"  to name,
                "load_ms" to loadMs,
            ))
        }
    }
}
