package com.unitrack.camerademo

import android.app.Application

/**
 * Application entry — fetch portal remote config, then start UniTrack.
 *
 * Matches the iOS AppDelegate flow:
 *   CameraAnalytics.bootstrap → start(remote: cfg)
 *     → addProvider(Snowplow), addProvider(Firebase), initialize(app, config)
 *   then sessionStarted / identify.
 */
class DemoApp : Application() {
    override fun onCreate() {
        super.onCreate()
        CameraAnalytics.bootstrap(this) {
            CameraAnalytics.identify("demo_user_42", "b2c_premium")
            CameraAnalytics.sessionStarted()
            CameraAnalytics.notificationPermissionChecked(granted = true)

            // Optional smoke-fire — drains the 30-event taxonomy in one shot so
            // CI/QA can verify portal coverage without driving the UI. Enable
            // via `adb shell setprop unitrack.autofire 1` then relaunch.
            if (getSystemProperty("unitrack.autofire") == "1") {
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    CameraAnalytics.fireAllForSmokeTest()
                }, 1500)
            }
        }
    }

    // Reflective getter for android.os.SystemProperties (hidden API on AOSP).
    // Returns null if anything goes wrong.
    private fun getSystemProperty(key: String): String? = try {
        val cls = Class.forName("android.os.SystemProperties")
        val m = cls.getMethod("get", String::class.java)
        m.invoke(null, key) as? String
    } catch (_: Throwable) { null }
}
