package com.unitrack.sdk

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle

/**
 * Drop-in deeplink auto-capture for Android.
 *
 * The OS routes external URLs (`<intent-filter android:action="VIEW">`) to an
 * Activity by setting the intent action to ACTION_VIEW + intent.data = the
 * launching URL. Hook ActivityLifecycleCallbacks.onActivityCreated and read
 * `intent.data` — the SDK gets every cold-start link without the app having
 * to call trackDeeplink() from every Activity.
 *
 * Call once in Application.onCreate (after UniTrack.initialize):
 *
 *     UniTrackDeeplinks.install(this)
 *
 * Runtime URLs (Activity already created, intent re-sent via onNewIntent)
 * aren't caught here — the app should still call
 * `UniTrack.trackDeeplink(intent.dataString, source = "new_intent")` from
 * onNewIntent. We don't swizzle onNewIntent because each Activity owns its
 * own override and there's no central funnel.
 */
object UniTrackDeeplinks {

    @Volatile private var installed = false

    @JvmStatic
    fun install(app: Application) {
        if (installed) return
        installed = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
                val intent = activity.intent ?: return
                // Only ACTION_VIEW intents carry an external URL the OS routed
                // to us. Other actions (MAIN, SEND, …) aren't deeplinks.
                if (intent.action != Intent.ACTION_VIEW) return
                val data = intent.data ?: return
                val url = data.toString()
                if (url.isNotEmpty()) {
                    UniTrack.trackDeeplink(url, "launch")
                }
            }
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }
}
