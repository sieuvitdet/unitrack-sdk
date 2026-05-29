package com.unitrack.demo

import android.app.Application
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.network.OkHttpTracker
import okhttp3.OkHttpClient

/**
 * App entry point — all UniTrack setup lives here (mirrors the iOS AppDelegate).
 *
 * After bootstrap, the SDK auto-captures (no per-screen code):
 *   • screen_view        — every Activity / Fragment on resume
 *   • tap                — button / switch taps (element_key from the view tag)
 *   • network_request    — OkHttp calls through [http]
 *   • app_start / app_foreground / app_background
 *   • session_start / session_end (journeyCapture)
 *   • memory_warning     — onTrimMemory pressure
 *
 * Config (endpoint, Snowplow, SDK flags, rewrite rules) is pulled from the
 * portal's remote config at launch — see [CameraAnalytics.bootstrap]. Only the
 * api_key + config URL are hardcoded (in CameraAnalytics).
 *
 * Crash capture: unlike iOS, the Android SDK does NOT auto-install a crash
 * handler, so we chain a Thread.UncaughtExceptionHandler that records a `crash`
 * event and flushes before the process dies.
 */
class DemoApp : Application() {

    override fun onCreate() {
        super.onCreate()

        installCrashHandler()

        // Fetch remote config from the portal, THEN init UniTrack from it.
        // Non-blocking: portal unreachable → cached/default config is used.
        CameraAnalytics.bootstrap(this) {
            CameraAnalytics.identify(userId = "demo_user_42", plan = "b2c_premium")
        }

        // OkHttp has no global hook — wrap the client we hand out to the app.
        http = OkHttpTracker.attach(OkHttpClient())

        // NOTE: the SDK already emits app_foreground/background + its own
        // session_start/session_end (journeyCapture). We do NOT add a manual
        // ActivityLifecycle session tracker here — besides duplicating those, it
        // can fire `track()` before the async bootstrap finishes loading the
        // native lib, which crashes with UnsatisfiedLinkError on nativeTrack.
    }

    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                // Only track if the native lib finished loading — otherwise the
                // crash report itself would crash on nativeTrack.
                if (CameraAnalytics.ready) {
                    UniTrack.track(
                        "crash",
                        mapOf(
                            "message" to (throwable.message ?: throwable.javaClass.simpleName),
                            "type" to throwable.javaClass.name,
                            "thread" to thread.name,
                            "stack" to throwable.stackTraceToString()
                                .lineSequence().take(20).joinToString("\n"),
                            "fatal" to true,
                        ),
                    )
                    UniTrack.flush()   // best-effort send before the process dies
                }
            } catch (_: Throwable) {
                // never mask the original crash
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    companion object {
        /** Shared, auto-captured HTTP client for the demo screens. */
        lateinit var http: OkHttpClient
            private set
    }
}
