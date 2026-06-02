// CameraAnalytics.kt
//
// Maps the camera/CCTV event taxonomy onto UniTrack. UniTrack auto-captures
// screen_view, tap, network_request, app_foreground/background, app_start and
// crash with ZERO code. The domain-specific camera events below are explicit
// track() calls — analytics SDKs can't infer "live stream started" from UI.
//
// This file is the single tracking surface for the whole app; the activities/
// fragments call these semantic methods so the taxonomy stays in one place.

package com.unitrack.camerademo

import android.app.Application
import android.os.Build
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.UniTrackConfig
import com.unitrack.sdk.UniTrackRemoteConfig
import com.unitrack.sdk.firebase.FirebaseProvider
import com.unitrack.sdk.snowplow.SnowplowOptions
import com.unitrack.sdk.snowplow.SnowplowProvider
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

object CameraAnalytics {

    // The ONLY hardcoded values: the bootstrap api_key + where to fetch config.
    // Everything else (ingest endpoint, Snowplow, Firebase, super-properties,
    // SDK flags) comes from the portal's remote config so it can change without
    // rebuilding the app.
    const val API_KEY    = "utk_6yC71Z4ZgPSIysijkh-ACf9g"
    const val CONFIG_URL = "https://mobix.asia/event-tracking-mobile/config"

    // Kept so super/user properties can be updated at runtime (e.g. after login).
    var firebase: FirebaseProvider? = null
    var snowplow: SnowplowProvider? = null

    /** Update Firebase custom data at runtime (e.g. once the user logs in). */
    fun updateFirebaseContext(userId: String, plan: String, region: String) {
        firebase?.setSuperProperty("user_id", userId)
        firebase?.setUserProperty("subscription_plan", plan)
        firebase?.setUserProperty("region", region)
    }

    /**
     * Fetch remote config from the portal, then start tracking. Never blocks
     * launch: on portal failure it uses the cached/built-in default config.
     */
    fun bootstrap(app: Application, done: () -> Unit) {
        UniTrackRemoteConfig.fetch(app, API_KEY, CONFIG_URL) { cfg ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                start(app, cfg)
                done()
            }
        }
    }

    /** Build UniTrackConfig + providers entirely from the fetched remote config. */
    fun start(app: Application, cfg: UniTrackRemoteConfig) {
        // Snowplow — only if the portal enabled it.
        val sp = cfg.snowplow
        val spEndpoint = sp.optString("endpoint", "")
        val spAppId    = sp.optString("appId", "")
        if (sp.optBoolean("enabled", false) && spEndpoint.isNotEmpty() && spAppId.isNotEmpty()) {
            val o = sp.optJSONObject("options") ?: JSONObject()
            val userCtx = sp.optJSONObject("user_context")?.let { jsonToMap(it).toMutableMap() }
                ?: mutableMapOf()
            // Convention table from the portal: kind → event name + entity name → iglu URI.
            val evNames = (sp.optJSONObject("event_names") ?: JSONObject()).let { obj ->
                obj.keys().asSequence().associateWith { obj.optString(it) }
            }
            val entities = (sp.optJSONObject("entities") ?: JSONObject()).let { obj ->
                obj.keys().asSequence().associateWith { obj.optString(it) }
            }
            val provider = SnowplowProvider(
                endpoint  = spEndpoint,
                appId     = spAppId,
                namespace = sp.optString("namespace", "UniTrack"),
                userContext = userCtx,
                options = SnowplowOptions(
                    base64Encoding              = o.optBoolean("base64Encoding", true),
                    platformContext             = o.optBoolean("platformContext", true),
                    applicationContext          = o.optBoolean("applicationContext", true),
                    sessionContext              = o.optBoolean("sessionContext", true),
                    screenContext               = o.optBoolean("screenContext", true),
                    lifecycleAutotracking       = o.optBoolean("lifecycleAutotracking", true),
                    screenEngagementAutotracking = o.optBoolean("screenEngagementAutotracking", true),
                    // OFF: UniTrack already emits screen_view; Snowplow's own
                    // ScreenView autotracking would double-count each screen.
                    exceptionAutotracking       = o.optBoolean("exceptionAutotracking", true),
                    installAutotracking         = o.optBoolean("installAutotracking", true),
                ),
                igluVendor     = sp.optString("iglu_vendor", "").ifEmpty { null },
                defaultVersion = sp.optString("default_version", "1-0-0"),
                eventNames     = evNames,
                entities       = entities,
            )
            UniTrack.addProvider(provider)
            snowplow = provider
        }

        // Firebase — only if enabled; configured at RUNTIME from portal values
        // (no google-services.json in the bundle, parity with iOS plist-less mode).
        val fb = cfg.firebase
        if (fb.optBoolean("enabled", false)) {
            val opt = fb.optJSONObject("options")
            val fbOptions = if (opt != null) {
                val appId    = opt.optString("appId", "")
                val sender   = opt.optString("gcmSenderId", "")
                if (appId.isNotEmpty() && sender.isNotEmpty()) FirebaseProvider.Options(
                    googleAppId = appId,
                    gcmSenderId = sender,
                    apiKey        = opt.optString("apiKey", "").ifEmpty { null },
                    projectId     = opt.optString("projectId", "").ifEmpty { null },
                    bundleId      = opt.optString("bundleId", "").ifEmpty { null },
                    storageBucket = opt.optString("storageBucket", "").ifEmpty { null },
                ) else null
            } else null
            val provider = FirebaseProvider(
                firebaseOptions = fbOptions,
                portalEndpoint  = cfg.endpoint,
                portalApiKey    = API_KEY,
                initialSuperProperties = jsonToMap(fb.optJSONObject("super_properties") ?: JSONObject()),
                initialUserProperties  = jsonToMap(fb.optJSONObject("user_properties") ?: JSONObject()),
            )
            UniTrack.addProvider(provider)
            firebase = provider
        }

        // Phase 2: rewrite rules from the portal. The SDK turns auto-captured
        // events (tap/screen/network) into business events by name — so adding
        // a NEW tracked moment for an existing screen/button needs no app code,
        // just a rule on the portal.
        UniTrack.setEventRules(cfg.toEventRules())

        // Core SDK config from the portal.
        val s = cfg.sdkConfig
        val config = UniTrackConfig(
            apiKey            = API_KEY,
            endpoint          = cfg.endpoint,
            batchSize         = s.optInt("batchSize", 10),
            flushIntervalMs   = s.optInt("flushIntervalMs", 3000),
            samplingRate      = s.optDouble("samplingRate", 1.0),
            autoCapture       = s.optBoolean("autoCapture", true),
            trackScreens      = s.optBoolean("trackScreens", true),
            trackTaps         = s.optBoolean("trackTaps", true),
            trackNetwork      = s.optBoolean("trackNetwork", true),
            journeyCapture    = s.optBoolean("journeyCapture", true),
            sessionTimeoutMs  = s.optInt("sessionTimeoutMs", 1_800_000),
            // Wire taxonomy overrides — sheet says screen_viewed/screen_exited,
            // core defaults to screen_start/screen_end.
            screenStartEvent  = s.optString("screenStartEvent", "screen_start"),
            screenEndEvent    = s.optString("screenEndEvent",   "screen_end"),
        )
        UniTrack.initialize(app, config)
    }

    // Sheet field naming notes:
    //   • camera_serial: B2C serial (cam_living_room etc.)
    //   • camera_id:     B2B VMS id (used in vms_* events)
    //   • watch_sec:     ms/1000 rounded — used in *_ended / *_played
    //   • action:        "play" | "pause" | "stop" for stream_paused / buffering
    //   • view_mode:     "single" | "grid" — UI display mode at the time

    // ── #1 session_started / #2 session_ended ────────────────────────────────
    fun sessionStarted() = UniTrack.track("session_started", mapOf("source" to "camera_demo"))
    fun sessionEnded(reason: String = "backgrounded") =
        UniTrack.track("session_ended", mapOf("reason" to reason))

    // ── #3 identify (sets user_id + properties) ──────────────────────────────
    fun identify(userId: String, plan: String) =
        UniTrack.identify(userId, mapOf("subscription_plan" to plan))

    // ── #5/#6/#7 camera_stream_started/ended/paused ──────────────────────────
    fun streamStarted(cameraSerial: String, channel: Int, viewMode: String, gridSize: Int) =
        UniTrack.track("camera_stream_started", mapOf(
            "camera_serial" to cameraSerial,
            "channel"       to channel,
            "view_mode"     to viewMode,
            "grid_size"     to gridSize,
        ))
    fun streamEnded(cameraSerial: String, watchSec: Int, viewMode: String) =
        UniTrack.track("camera_stream_ended", mapOf(
            "camera_serial" to cameraSerial,
            "watch_sec"     to watchSec,
            "view_mode"     to viewMode,
        ))
    fun streamPaused(cameraSerial: String) =
        UniTrack.track("camera_stream_paused", mapOf("camera_serial" to cameraSerial, "action" to "pause"))

    // ── #8 camera_event_viewed (recording motion/AI alert) ───────────────────
    fun eventViewed(cameraSerial: String, channel: Int = 1) =
        UniTrack.track("camera_event_viewed", mapOf(
            "camera_serial" to cameraSerial, "channel" to channel,
        ))

    // ── #9/#10 camera_playback_started/ended ────────────────────────────────
    fun playbackStarted(cameraSerial: String, channel: Int = 1) =
        UniTrack.track("camera_playback_started", mapOf(
            "camera_serial" to cameraSerial, "channel" to channel,
        ))
    fun playbackEnded(cameraSerial: String, watchSec: Int) =
        UniTrack.track("camera_playback_ended", mapOf(
            "camera_serial" to cameraSerial, "watch_sec" to watchSec,
        ))

    // ── #11 notification_permission_checked ──────────────────────────────────
    fun notificationPermissionChecked(granted: Boolean) =
        UniTrack.track("notification_permission_checked", mapOf("granted" to granted))

    // ── #12/#13/#14 camera_notification_sent/delivered/clicked ───────────────
    fun notificationSent(cameraSerial: String, notificationType: String) =
        UniTrack.track("camera_notification_sent", mapOf(
            "camera_serial"     to cameraSerial, "notification_type" to notificationType,
        ))
    fun notificationDelivered(cameraSerial: String, notificationType: String) =
        UniTrack.track("camera_notification_delivered", mapOf(
            "camera_serial"     to cameraSerial, "notification_type" to notificationType,
        ))
    fun notificationClicked(cameraSerial: String, notificationLabel: String) =
        UniTrack.track("camera_notification_clicked", mapOf(
            "camera_serial"      to cameraSerial, "notification_label" to notificationLabel,
        ))

    // ── #15 camera_ai_feature_toggled ────────────────────────────────────────
    fun aiFeatureToggled(cameraSerial: String, aiFeatureCode: String, on: Boolean) =
        UniTrack.track("camera_ai_feature_toggled", mapOf(
            "camera_serial"   to cameraSerial,
            "ai_feature_code" to aiFeatureCode,
            "action"          to if (on) "on" else "off",
        ))

    // ── #16/#17 VMS live ─────────────────────────────────────────────────────
    fun vmsCameraConnected(cameraId: String, gridSize: Int, viewMode: String) =
        UniTrack.track("vms_camera_connected", mapOf(
            "camera_id" to cameraId, "grid_size" to gridSize, "view_mode" to viewMode,
        ))
    fun vmsCameraDisconnected(cameraId: String, watchSec: Int) =
        UniTrack.track("vms_camera_disconnected", mapOf(
            "camera_id" to cameraId, "watch_sec" to watchSec,
        ))

    // ── #18 vms_recording_played ─────────────────────────────────────────────
    fun vmsRecordingPlayed(cameraId: String, watchSec: Int) =
        UniTrack.track("vms_recording_played", mapOf(
            "camera_id" to cameraId, "watch_sec" to watchSec,
        ))

    // ── #19 vms_alert_viewed ─────────────────────────────────────────────────
    fun vmsAlertViewed(cameraId: String, alertType: String) =
        UniTrack.track("vms_alert_viewed", mapOf(
            "camera_id" to cameraId, "alert_type" to alertType,
        ))

    // ── #20/#21 camera_shared / camera_share_revoked ─────────────────────────
    fun cameraShared(cameraSerial: String, sharedWithUserId: String) =
        UniTrack.track("camera_shared", mapOf(
            "camera_serial"       to cameraSerial,
            "shared_with_user_id" to sharedWithUserId,
        ))
    fun cameraShareRevoked(cameraSerial: String, sharedWithUserId: String) =
        UniTrack.track("camera_share_revoked", mapOf(
            "camera_serial"       to cameraSerial,
            "shared_with_user_id" to sharedWithUserId,
        ))

    // ── #22/#23/#24/#25 camera_pairing_started / _completed / _failed / camera_registered
    fun pairingStarted() = UniTrack.track("camera_pairing_started", emptyMap())
    fun pairingCompleted(cameraSerial: String) =
        UniTrack.track("camera_pairing_completed", mapOf("camera_serial" to cameraSerial))
    fun pairingFailed(errorCode: String) =
        UniTrack.track("camera_pairing_failed", mapOf("error_code" to errorCode))
    fun cameraRegistered(cameraSerial: String, model: String) =
        UniTrack.track("camera_registered", mapOf(
            "camera_serial" to cameraSerial, "model" to model,
        ))

    // ── #26 screen_load_completed — auto by SDK swizzler ─────────────────────

    // ── #27/#28 camera_stream_first_frame / camera_stream_buffering ─────────
    fun streamFirstFrame(cameraSerial: String, ttffMs: Int, featureType: String) =
        UniTrack.track("camera_stream_first_frame", mapOf(
            "camera_serial" to cameraSerial,
            "ttff_ms"       to ttffMs,
            "feature_type"  to featureType,
        ))
    fun streamBuffering(cameraSerial: String, action: String, bufferingDurationMs: Int) =
        UniTrack.track("camera_stream_buffering", mapOf(
            "camera_serial"          to cameraSerial,
            "action"                 to action,
            "buffering_duration_ms"  to bufferingDurationMs,
        ))

    // ── #29 camera_item_selected ─────────────────────────────────────────────
    fun cameraItemSelected(cameraSerial: String, sourceScreen: String) =
        UniTrack.track("camera_item_selected", mapOf(
            "camera_serial" to cameraSerial,
            "source_screen" to sourceScreen,
        ))

    // ── #30 application_error (non-fatal). Hard crashes (signal-trapped) flow
    // through the SDK's own `crash` event on next launch, not this helper.
    fun applicationError(exceptionName: String, message: String, isFatal: Boolean = false) =
        UniTrack.track("application_error", mapOf(
            "exception_name" to exceptionName,
            "message"        to message,
            "is_fatal"       to isFatal,
        ))

    /** Smoke-test helper — fire every semantic event once. Useful for CI coverage. */
    fun fireAllForSmokeTest() {
        val cam = "cam_living_room"
        val friend = "friend_07"
        val nvr = "nvr_hq_01_ch3"
        notificationPermissionChecked(true)
        streamStarted(cam, 1, "single", 1)
        streamFirstFrame(cam, 620, "live")
        streamBuffering(cam, "start", 350)
        streamPaused(cam)
        streamEnded(cam, 12, "single")
        eventViewed(cam, 1)
        playbackStarted(cam, 1)
        playbackEnded(cam, 30)
        notificationSent(cam, "motion")
        notificationDelivered(cam, "motion")
        notificationClicked(cam, "Motion at Living Room")
        aiFeatureToggled(cam, "person_detection", true)
        vmsCameraConnected(nvr, 4, "grid")
        vmsCameraDisconnected(nvr, 60)
        vmsRecordingPlayed(nvr, 30)
        vmsAlertViewed(nvr, "line_crossing")
        cameraShared(cam, friend)
        cameraShareRevoked(cam, friend)
        pairingStarted()
        pairingCompleted("cam_new_99")
        pairingFailed("E_TIMEOUT")
        cameraRegistered("cam_new_99", "FPT-Cam V2")
        cameraItemSelected(cam, "MainActivity")
        applicationError("SmokeTest", "fired by fireAllForSmokeTest()", false)
    }

    // ── JSONObject → Map<String,Any?> (recursive) ────────────────────────────
    // Snowplow blueprints/entities are nested JSON; the engine needs Kotlin maps.
    @Suppress("UNCHECKED_CAST")
    fun jsonToMap(o: JSONObject): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        for (k in o.keys()) {
            val v = o.get(k)
            out[k] = when (v) {
                is JSONObject -> jsonToMap(v)
                is JSONArray  -> jsonToList(v)
                JSONObject.NULL -> null
                else -> v
            }
        }
        return out
    }

    fun jsonToList(a: JSONArray): List<Any?> {
        val out = ArrayList<Any?>(a.length())
        for (i in 0 until a.length()) {
            when (val v = a.get(i)) {
                is JSONObject -> out.add(jsonToMap(v))
                is JSONArray  -> out.add(jsonToList(v))
                JSONObject.NULL -> out.add(null)
                else -> out.add(v)
            }
        }
        return out
    }
}
