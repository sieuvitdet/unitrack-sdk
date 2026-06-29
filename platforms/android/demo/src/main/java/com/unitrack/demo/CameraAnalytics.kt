package com.unitrack.demo

import android.app.Application
import android.util.Log
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.UniTrackConfig
import com.unitrack.sdk.UniTrackRemoteConfig
import com.unitrack.sdk.snowplow.SnowplowProvider

/**
 * Maps the camera/CCTV event taxonomy onto UniTrack (mirrors the iOS demo's
 * CameraAnalytics). The SDK auto-captures screen_view, tap, network_request,
 * app_foreground/background, app_start, session_start/end and memory_warning
 * with ZERO code. The domain events below are explicit track() calls — an
 * analytics SDK can't infer "live stream started" from UI.
 *
 * This is the single tracking surface for the whole app.
 */
object CameraAnalytics {

    // The ONLY hardcoded values: the bootstrap api_key + where to fetch config.
    // Everything else (ingest endpoint, Snowplow, SDK flags, rewrite rules)
    // comes from the portal's remote config so it can change without rebuilding.
    const val apiKey = "utk_eCt1OHqoWWcNz-oae5E2GdAU"
    const val configURL = "https://mobix.asia/event-tracking-mobile/config"

    /**
     * Fetch remote config from the portal, then start tracking. Never blocks
     * launch: on portal failure it uses cached/built-in default config. The
     * [done] callback runs after initialize() so SDK-dependent tracking is safe.
     */
    fun bootstrap(app: Application, done: () -> Unit) {
        UniTrackRemoteConfig.fetch(app, apiKey, configURL, flavor = null, timeoutMs = 3000) { cfg ->
            app.mainExecutorCompat {
                start(app, cfg)
                done()
            }
        }
    }

    /** Build UniTrackConfig + providers entirely from the fetched remote config. */
    private fun start(app: Application, cfg: UniTrackRemoteConfig) {
        // Snowplow — only if the portal enabled it. Wrapped so a provider/lib
        // issue can never break app launch.
        try {
            val sp = cfg.snowplow
            if (sp.optBoolean("enabled", false)) {
                val endpoint = sp.optString("endpoint", "")
                val appId = sp.optString("appId", "")
                if (endpoint.isNotEmpty() && appId.isNotEmpty()) {
                    UniTrack.addProvider(SnowplowProvider(endpoint = endpoint, appId = appId))
                    Log.i("CameraAnalytics", "Snowplow provider added → $endpoint")
                }
            }
        } catch (t: Throwable) {
            Log.w("CameraAnalytics", "Snowplow provider init skipped: ${t.message}")
        }

        // Firebase Analytics mirror — host app provides google-services.json
        // + google-services Gradle plugin → FirebaseAnalytics auto-init →
        // 1 dòng `UniTrack.attachFirebaseAdapter(app)` để stamp session_id
        // vào mọi event Firebase. Adapter dùng reflection, không cần module
        // riêng.

        // (Phase 2 rewrite-rule wiring removed — superseded by the convention
        // layer which routes raw event names → kinds → schemas in the
        // Snowplow provider. App-side businees events go through
        // UniTrack.track() / convention helpers directly.)

        // Core SDK config from the portal (with sensible fallbacks).
        val s = cfg.sdkConfig
        UniTrack.initialize(
            app,
            UniTrackConfig(
                apiKey = apiKey,
                endpoint = cfg.endpoint,
                batchSize = s.optInt("batchSize", 10),
                flushIntervalMs = s.optInt("flushIntervalMs", 3000),
                samplingRate = s.optDouble("samplingRate", 1.0),
                autoCapture = s.optBoolean("autoCapture", true),
                trackScreens = s.optBoolean("trackScreens", true),
                trackTaps = s.optBoolean("trackTaps", true),
                trackNetwork = s.optBoolean("trackNetwork", true),
                journeyCapture = true,
                // Screen lifecycle (renameable). Pull names from remote config
                // so a team can map them onto their own taxonomy without an
                // app rebuild.
                screenLifecycle = s.optBoolean("screen_lifecycle", true),
                screenStartEvent = s.optString("screen_start_event", "screen_start"),
                screenEndEvent = s.optString("screen_end_event", "screen_end"),
            ),
        )
        ready = true   // native lib is now loaded + initialized
    }

    /** True once UniTrack.initialize has run (native lib loaded). Guards any
     *  manual track() that could fire before the async bootstrap completes. */
    @Volatile var ready = false
        private set

    fun identify(userId: String, plan: String) {
        if (ready) UniTrack.identify(userId, mapOf("plan" to plan))
    }

    // ── Session (mirrors iOS #1, #2). The SDK also emits its own
    //    session_start/session_end via journeyCapture; these are the explicit
    //    app-level markers the iOS demo uses. ────────────────────────────────
    fun sessionStarted() { if (ready) UniTrack.track("session_started", mapOf("source" to "app_open")) }
    fun sessionEnded(reason: String) { if (ready) UniTrack.track("session_ended", mapOf("reason" to reason)) }

    // ── Camera live streaming B2C (#5, #6, #7) ───────────────────────────────
    fun streamStarted(cameraId: String, quality: String) =
        UniTrack.track("camera_stream_started", mapOf("camera_id" to cameraId, "quality" to quality))
    fun streamEnded(cameraId: String, durationMs: Int) =
        UniTrack.track("camera_stream_ended", mapOf("camera_id" to cameraId, "duration_ms" to durationMs))
    fun streamPaused(cameraId: String) =
        UniTrack.track("camera_stream_paused", mapOf("camera_id" to cameraId))

    // ── Camera events & playback B2C (#8, #9, #10) ───────────────────────────
    fun eventViewed(cameraId: String, eventType: String) =
        UniTrack.track("camera_event_viewed", mapOf("camera_id" to cameraId, "event_type" to eventType))
    fun playbackStarted(cameraId: String, recordingId: String) =
        UniTrack.track("camera_playback_started", mapOf("camera_id" to cameraId, "recording_id" to recordingId))
    fun playbackEnded(cameraId: String, durationMs: Int) =
        UniTrack.track("camera_playback_ended", mapOf("camera_id" to cameraId, "duration_ms" to durationMs))

    // ── Notifications (#11, #12, #13, #14) ───────────────────────────────────
    fun notificationPermissionChecked(granted: Boolean) =
        UniTrack.track("notification_permission_checked", mapOf("granted" to granted))
    fun notificationSent(cameraId: String, type: String) =
        UniTrack.track("camera_notification_sent", mapOf("camera_id" to cameraId, "type" to type))
    fun notificationDelivered(cameraId: String, type: String) =
        UniTrack.track("camera_notification_delivered", mapOf("camera_id" to cameraId, "type" to type))
    fun notificationClicked(cameraId: String, type: String) =
        UniTrack.track("camera_notification_clicked", mapOf("camera_id" to cameraId, "type" to type))

    // ── Camera settings B2C (#15) ────────────────────────────────────────────
    fun aiFeatureToggled(cameraId: String, feature: String, enabled: Boolean) =
        UniTrack.track("camera_ai_feature_toggled", mapOf("camera_id" to cameraId, "feature" to feature, "enabled" to enabled))

    // ── VMS B2B (#16, #17, #18, #19) ─────────────────────────────────────────
    fun vmsCameraConnected(nvrId: String, channel: Int) =
        UniTrack.track("vms_camera_connected", mapOf("nvr_id" to nvrId, "channel" to channel))
    fun vmsCameraDisconnected(nvrId: String, channel: Int) =
        UniTrack.track("vms_camera_disconnected", mapOf("nvr_id" to nvrId, "channel" to channel))
    fun vmsRecordingPlayed(nvrId: String, channel: Int, recordingId: String) =
        UniTrack.track("vms_recording_played", mapOf("nvr_id" to nvrId, "channel" to channel, "recording_id" to recordingId))
    fun vmsAlertViewed(nvrId: String, alertType: String) =
        UniTrack.track("vms_alert_viewed", mapOf("nvr_id" to nvrId, "alert_type" to alertType))

    // ── Camera sharing B2C (#20, #21) ────────────────────────────────────────
    fun cameraShared(cameraId: String, withUser: String) =
        UniTrack.track("camera_shared", mapOf("camera_id" to cameraId, "shared_with" to withUser))
    fun cameraShareRevoked(cameraId: String, fromUser: String) =
        UniTrack.track("camera_share_revoked", mapOf("camera_id" to cameraId, "revoked_from" to fromUser))

    // ── Onboarding / pairing (#22, #23, #24, #25) ────────────────────────────
    fun pairingStarted(method: String) =
        UniTrack.track("camera_pairing_started", mapOf("method" to method))
    fun pairingCompleted(cameraId: String, durationMs: Int) =
        UniTrack.track("camera_pairing_completed", mapOf("camera_id" to cameraId, "duration_ms" to durationMs))
    fun pairingFailed(reason: String, code: String) =
        UniTrack.track("camera_pairing_failed", mapOf("reason" to reason, "error_code" to code))
    fun cameraRegistered(cameraId: String, model: String) =
        UniTrack.track("camera_registered", mapOf("camera_id" to cameraId, "model" to model))

    // ── Performance metrics (#27, #28) ───────────────────────────────────────
    fun streamFirstFrame(cameraId: String, ttffMs: Int) =
        UniTrack.track("camera_stream_first_frame", mapOf("camera_id" to cameraId, "ttff_ms" to ttffMs))
    fun streamBuffering(cameraId: String, durationMs: Int) =
        UniTrack.track("camera_stream_buffering", mapOf("camera_id" to cameraId, "duration_ms" to durationMs))

    // ── Interactions & errors (#29, #30) ─────────────────────────────────────
    fun cameraItemSelected(cameraId: String, position: Int) =
        UniTrack.track("camera_item_selected", mapOf("camera_id" to cameraId, "position" to position))
    /** Handled / non-fatal error (real crashes are auto-captured separately). */
    fun applicationError(domain: String, message: String, fatal: Boolean = false) =
        UniTrack.track("application_error", mapOf("domain" to domain, "message" to message, "fatal" to fatal))
}

/** Run a block on the app's main thread (small Executor-vs-Handler compat shim). */
private fun Application.mainExecutorCompat(block: () -> Unit) {
    android.os.Handler(android.os.Looper.getMainLooper()).post(block)
}
