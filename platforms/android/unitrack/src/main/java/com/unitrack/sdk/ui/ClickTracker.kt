package com.unitrack.sdk.ui

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.Window
import com.unitrack.sdk.UniTrack

/**
 * Tap tracker.
 *
 * Strategy: wrap each Activity's Window.Callback so we observe every
 * dispatched touch event. On ACTION_UP we walk the view hierarchy to
 * find the deepest clickable View under the touch point and emit a tap.
 *
 * Element-key resolution order:
 *   1. View.tag if String
 *   2. View resource entry name (android:id)
 *   3. contentDescription
 *   4. button text
 *   5. "ClassName"
 */
internal object ClickTracker : Application.ActivityLifecycleCallbacks {

    fun install(app: Application) {
        app.unregisterActivityLifecycleCallbacks(this)
        app.registerActivityLifecycleCallbacks(this)
    }

    override fun onActivityCreated(a: Activity, b: Bundle?) {
        val w = a.window ?: return
        val original = w.callback ?: return
        w.callback = TrackingCallback(original, w)
    }

    // ─── unused ───────────────────────────────────────────────────────────
    override fun onActivityStarted(a: Activity) {}
    override fun onActivityResumed(a: Activity) {}
    override fun onActivityPaused(a: Activity) {}
    override fun onActivityStopped(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
    override fun onActivityDestroyed(a: Activity) {}

    // ─── delegating window callback ───────────────────────────────────────
    private class TrackingCallback(
        private val delegate: Window.Callback,
        private val window: Window
    ) : Window.Callback by delegate {

        override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
            // Capture on ACTION_UP — the gesture has settled.
            if (ev.action == MotionEvent.ACTION_UP) {
                try { capture(ev) } catch (_: Throwable) { /* defensive */ }
            }
            return delegate.dispatchTouchEvent(ev)
        }

        override fun dispatchKeyEvent(ev: KeyEvent): Boolean =
            delegate.dispatchKeyEvent(ev)

        private fun capture(ev: MotionEvent) {
            val decor = window.decorView as? View ?: return
            val target = findTarget(decor, ev.rawX.toInt(), ev.rawY.toInt())
                ?: return

            val key   = resolveKey(target)
            val ctx   = target.context
            // Use the Activity CLASS NAME as the screen (matches ActivityTracker
            // + the iOS swizzler); not activity.title, which is dynamic.
            val screen = (ctx as? Activity)?.javaClass?.simpleName ?: ""

            UniTrack.track("tap", mapOf(
                "element_key" to key,
                "screen"      to screen,
                "type"        to target.javaClass.simpleName
            ))
        }

        private fun findTarget(root: View, rawX: Int, rawY: Int): View? {
            // Walk the tree depth-first, returning the deepest clickable
            // view whose bounds contain the touch.
            val loc = IntArray(2)
            fun hits(v: View): Boolean {
                v.getLocationOnScreen(loc)
                val x0 = loc[0]; val y0 = loc[1]
                return rawX in x0..(x0 + v.width) &&
                       rawY in y0..(y0 + v.height)
            }
            var best: View? = null
            fun dfs(v: View) {
                if (!hits(v) || v.visibility != View.VISIBLE) return
                if (v.isClickable || v.hasOnClickListeners()) best = v
                if (v is android.view.ViewGroup) {
                    for (i in 0 until v.childCount) dfs(v.getChildAt(i))
                }
            }
            dfs(root)
            return best
        }

        private fun resolveKey(v: View): String {
            (v.tag as? String)?.takeIf { it.isNotBlank() }?.let { return it }

            if (v.id != View.NO_ID) {
                try {
                    val n = v.resources.getResourceEntryName(v.id)
                    if (!n.isNullOrBlank()) return n
                } catch (_: Throwable) {}
            }
            v.contentDescription?.toString()?.takeIf { it.isNotBlank() }
                ?.let { return "desc:$it" }

            if (v is android.widget.TextView) {
                v.text?.toString()?.takeIf { it.isNotBlank() }
                    ?.let { return "text:${it.take(40)}" }
            }
            return v.javaClass.simpleName
        }
    }
}
