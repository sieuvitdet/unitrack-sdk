package com.unitrack.sdk.firebase

import android.app.Application
import android.os.Bundle
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.analytics.FirebaseAnalytics
import com.unitrack.sdk.providers.AnalyticsProvider
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.locks.ReentrantLock

/**
 * Forwards every UniTrack event to Firebase Analytics + (optional) mirrors a
 * tagged copy to the portal so the portal session view can show "forward → firebase".
 *
 * Two init modes:
 *   • google-services.json present → pass [firebaseOptions]=null, Firebase auto-inits.
 *   • Runtime config from the portal (no google-services.json shipped) → pass
 *     [firebaseOptions] built from the portal's firebase.options block.
 *
 *     UniTrack.addProvider(FirebaseProvider(
 *         firebaseOptions = options,
 *         portalEndpoint  = cfg.endpoint,
 *         portalApiKey    = apiKey,
 *         superProperties = mapOf("user_id" to "demo_user_42"),
 *         userProperties  = mapOf("subscription_plan" to "b2c_premium")))
 *
 * Firebase imposes strict naming rules (event/param names ≤40 chars,
 * alphanumeric + underscore, start with a letter; values String/Long/Double/
 * Bundle), so names and parameters are sanitized.
 */
class FirebaseProvider @JvmOverloads constructor(
    private val firebaseOptions: Options? = null,
    private val portalEndpoint: String? = null,
    private val portalApiKey:   String? = null,
    initialSuperProperties: Map<String, Any?> = emptyMap(),
    private val initialUserProperties: Map<String, Any?> = emptyMap(),
) : AnalyticsProvider {

    /** Mirror of FirebaseOptions — same field names as iOS so portal config maps 1:1. */
    data class Options(
        val googleAppId: String,
        val gcmSenderId: String,
        val apiKey: String? = null,
        val projectId: String? = null,
        val bundleId: String? = null,
        val storageBucket: String? = null,
    )

    private var fa: FirebaseAnalytics? = null
    private val lock = ReentrantLock()
    private val superProperties = HashMap<String, Any?>(initialSuperProperties)

    override fun initialize(app: Application) {
        // Only configure FirebaseApp when the app didn't ship a google-services.json
        // (FirebaseApp.getApps is empty until either google-services or initializeApp).
        if (FirebaseApp.getApps(app).isEmpty()) {
            val o = firebaseOptions ?: run {
                com.unitrack.sdk.UniTrack.log("UniTrackFirebase",
                    "no FirebaseOptions and no google-services.json — provider disabled")
                return
            }
            val builder = FirebaseOptions.Builder()
                .setApplicationId(o.googleAppId)
                .setGcmSenderId(o.gcmSenderId)
            o.apiKey?.let { builder.setApiKey(it) }
            o.projectId?.let { builder.setProjectId(it) }
            o.storageBucket?.let { builder.setStorageBucket(it) }
            FirebaseApp.initializeApp(app, builder.build())
        }
        fa = FirebaseAnalytics.getInstance(app)

        // Apply initial user properties (for audiences/segmentation).
        for ((k, v) in initialUserProperties) {
            fa?.setUserProperty(sanitizeName(k), stringify(v))
        }

        // Don't let UniTrack capture our portal-mirror uploads (feedback loop).
        portalEndpoint?.let { ep ->
            runCatching { URL(ep).host }.getOrNull()?.let {
                com.unitrack.sdk.UniTrack.excludeFromNetworkCapture(it)
            }
        }
        // CRUCIAL: Firebase Analytics itself POSTs measurement data to these
        // Google hosts. Without excluding them, UniTrack auto-captures each
        // Firebase upload as a network_request, then forwards it back to
        // Firebase/Snowplow → captured again → an endless amplifying loop.
        for (host in arrayOf(
            "app-measurement.com",
            "firebase-settings.crashlytics.com",
            "firebaseinstallations.googleapis.com",
            "firebaseremoteconfig.googleapis.com",
            "google-analytics.com",
            "analytics.google.com",
        )) com.unitrack.sdk.UniTrack.excludeFromNetworkCapture(host)

        com.unitrack.sdk.UniTrack.log("UniTrackFirebase", "Firebase Analytics ready")
    }

    override fun track(name: String, properties: Map<String, Any?>) {
        // Merge super properties under the event's own (event props win).
        val merged = HashMap<String, Any?>()
        lock.lock(); try { merged.putAll(superProperties) } finally { lock.unlock() }
        merged.putAll(properties)
        val sanitizedName = sanitizeName(name)
        val bundle = toBundle(merged)
        fa?.logEvent(sanitizedName, bundle)
        com.unitrack.sdk.UniTrack.log("UniTrackFirebase",
            "SEND event=\"$name\" (sanitized=\"$sanitizedName\") params=${org.json.JSONObject(merged)}")
        mirrorToPortal(name, merged)
    }

    override fun setUser(userId: String?, traits: Map<String, Any?>) {
        fa?.setUserId(userId)
        for ((k, v) in traits) {
            fa?.setUserProperty(sanitizeName(k), stringify(v))
        }
    }

    override fun setScreen(name: String) {
        fa?.logEvent(FirebaseAnalytics.Event.SCREEN_VIEW, Bundle().apply {
            putString(FirebaseAnalytics.Param.SCREEN_NAME, name)
        })
    }

    /** Update a super property at runtime (e.g. after login changes user_id). */
    fun setSuperProperty(key: String, value: Any?) {
        lock.lock(); try { superProperties[key] = value } finally { lock.unlock() }
    }

    /** Update a Firebase user property at runtime (audiences/segmentation). */
    fun setUserProperty(key: String, value: Any?) {
        fa?.setUserProperty(sanitizeName(key), stringify(value))
    }

    // Fire-and-forget copy to the portal, tagged provider=firebase.
    private fun mirrorToPortal(name: String, properties: Map<String, Any?>) {
        val ep = portalEndpoint?.takeIf { it.isNotEmpty() } ?: run {
            com.unitrack.sdk.UniTrack.log("UniTrackFirebase",
                "MIRROR-SKIP \"$name\" (no portal endpoint)")
            return
        }
        val key = portalApiKey?.takeIf { it.isNotEmpty() } ?: run {
            com.unitrack.sdk.UniTrack.log("UniTrackFirebase",
                "MIRROR-SKIP \"$name\" (no portal api key)")
            return
        }
        val url = ep + (if (ep.contains('?')) "&" else "?") + "provider=firebase"
        val payload = org.json.JSONObject()
            .put("event_id", "${System.currentTimeMillis() * 1000}_$name")
            .put("event_name", name)
            .put("timestamp", System.currentTimeMillis())
            .put("properties", org.json.JSONObject(properties.mapValues { it.value ?: org.json.JSONObject.NULL }))
        val body = payload.toString().toByteArray(Charsets.UTF_8)

        Thread {
            try {
                val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Authorization", "Bearer $key")
                    connectTimeout = 5000
                    readTimeout = 5000
                    doOutput = true
                }
                conn.outputStream.use { it.write(body) }
                conn.inputStream.use { it.readBytes() }
                conn.disconnect()
                com.unitrack.sdk.UniTrack.log("UniTrackFirebase",
                    "MIRROR → portal url=$url bytes=${body.size}")
            } catch (_: Throwable) { /* ignored */ }
        }.start()
    }

    // --- Firebase naming/value constraints ----------------------------------

    private val illegal = Regex("[^a-zA-Z0-9_]")

    private fun sanitizeName(name: String): String {
        var s = name.replace(illegal, "_")
        if (s.isNotEmpty() && !s.first().isLetter()) s = "e_$s"
        if (s.length > 40) s = s.substring(0, 40)
        return s
    }

    private fun stringify(v: Any?): String? = when (v) {
        null -> null
        is String -> v
        else -> v.toString()
    }

    private fun toBundle(props: Map<String, Any?>): Bundle {
        val b = Bundle()
        for ((k, v) in props) {
            if (v == null) continue
            val key = sanitizeName(k)
            when (v) {
                is Long    -> b.putLong(key, v)
                is Int     -> b.putLong(key, v.toLong())
                is Double  -> b.putDouble(key, v)
                is Float   -> b.putDouble(key, v.toDouble())
                is Boolean -> b.putString(key, v.toString())
                is String  -> b.putString(key, if (v.length > 100) v.substring(0, 100) else v)
                else       -> {
                    val s = v.toString()
                    b.putString(key, if (s.length > 100) s.substring(0, 100) else s)
                }
            }
        }
        return b
    }
}
