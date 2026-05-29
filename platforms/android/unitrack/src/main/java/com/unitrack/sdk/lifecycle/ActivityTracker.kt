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
    }

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
    private val fragmentCb = object : FragmentManager.FragmentLifecycleCallbacks() {
        override fun onFragmentResumed(fm: FragmentManager, f: Fragment) {
            // Skip framework / nav-host fragments.
            val name = f.javaClass.simpleName
            if (name.startsWith("Nav") || name == "ReportFragment") return
            UniTrack.setScreen(name)
        }
    }
}
