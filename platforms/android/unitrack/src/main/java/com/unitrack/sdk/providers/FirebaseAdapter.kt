package com.unitrack.sdk.providers

import android.app.Application
import android.os.Bundle
import android.util.Log

/**
 * Provider Adapter that stamps UniTrack `session_id` onto every Firebase
 * Analytics event WITHOUT importing Firebase.
 *
 * Why reflection: UniTrack core module must stay 0-dep on Firebase. Apps that
 *   - never use Firebase   → no transitive pull, no app-size hit
 *   - use Firebase later   → adapter auto-detects at runtime, just works
 *   - use Firebase already → 1 dòng `UniTrack.attachFirebaseAdapter(app)`
 *
 * Mechanism: lookup `com.google.firebase.analytics.FirebaseAnalytics` via
 * `Class.forName`. If present:
 *   - on every event → call `logEvent(name, bundle)` mirroring UniTrack's
 *     props + session_id
 *   - on session rotate (track time) → call `setUserProperty("ut_session_id",
 *     ...)` so BigQuery exports + user_properties carry the id retroactively
 *
 * Portal toggle: respects `provider.firebase.enabled` flag. App can flip the
 * toggle without rebuilding — adapter reads at fire time, not at attach time.
 */
class FirebaseAdapter private constructor(
    private val firebaseClass: Class<*>,
    private val firebaseInstance: Any,
) : AnalyticsProvider {

    override val providerId: String get() = "FirebaseAdapter"

    @Volatile private var lastStampedSessionId: String? = null

    override fun initialize(app: Application) { /* Firebase brought up by host */ }

    override fun track(name: String, properties: Map<String, Any?>) {
        if (!isEnabled()) return
        try {
            maybeStampUserProperty()
            val bundle = toBundle(properties)
            // Mirror session_id at event level too so per-event analyses
            // (vd funnel widgets) don't depend on user-property joins.
            try { bundle.putString("session_id", com.unitrack.sdk.UniTrack.currentSessionId()) }
            catch (_: Throwable) {}
            val m = firebaseClass.getMethod("logEvent", String::class.java, Bundle::class.java)
            m.invoke(firebaseInstance, sanitize(name), bundle)
        } catch (e: Throwable) {
            Log.w(TAG, "logEvent reflection failed: ${e.message}")
        }
    }

    override fun setUser(userId: String?, traits: Map<String, Any?>) {
        if (!isEnabled()) return
        try {
            val setId = firebaseClass.getMethod("setUserId", String::class.java)
            setId.invoke(firebaseInstance, userId)
            val setProp = firebaseClass.getMethod("setUserProperty", String::class.java, String::class.java)
            for ((k, v) in traits) {
                setProp.invoke(firebaseInstance, sanitize(k), v?.toString() ?: "")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "setUser reflection failed: ${e.message}")
        }
    }

    override fun setScreen(name: String) { /* setScreen propagates via track(screen_view) */ }

    private fun maybeStampUserProperty() {
        try {
            val sid = com.unitrack.sdk.UniTrack.currentSessionId()
            if (sid.isEmpty() || sid == lastStampedSessionId) return
            val setProp = firebaseClass.getMethod("setUserProperty", String::class.java, String::class.java)
            setProp.invoke(firebaseInstance, "ut_session_id", sid)
            val idx = com.unitrack.sdk.UniTrack.sessionIndex()
            setProp.invoke(firebaseInstance, "ut_session_index", idx.toString())
            lastStampedSessionId = sid
        } catch (_: Throwable) { /* swallow */ }
    }

    private fun isEnabled(): Boolean {
        // Portal toggle. Default ON if app loaded the adapter — the only way
        // the adapter even exists is the app explicitly called attach().
        return try {
            !com.unitrack.sdk.UniTrack.getRemoteString("provider.firebase.enabled", "true")
                .equals("false", ignoreCase = true)
        } catch (_: Throwable) { true }
    }

    private fun toBundle(props: Map<String, Any?>): Bundle {
        val b = Bundle()
        for ((k, v) in props) {
            val key = sanitize(k)
            when (v) {
                null -> {}
                is String  -> b.putString(key, v)
                is Int     -> b.putLong(key, v.toLong())
                is Long    -> b.putLong(key, v)
                is Boolean -> b.putLong(key, if (v) 1L else 0L)
                is Float   -> b.putDouble(key, v.toDouble())
                is Double  -> b.putDouble(key, v)
                else       -> b.putString(key, v.toString())
            }
        }
        return b
    }

    /** Firebase rejects names with `[^A-Za-z0-9_]` or starting with a digit. */
    private fun sanitize(s: String): String {
        val sb = StringBuilder(s.length)
        for ((i, c) in s.withIndex()) {
            val ok = c.isLetterOrDigit() || c == '_'
            sb.append(if (ok) c else '_')
            if (i == 0 && c.isDigit()) sb.insert(0, '_')
        }
        return sb.toString().take(40)  // Firebase max name length
    }

    companion object {
        private const val TAG = "UTFirebaseAdapter"

        /**
         * Try to load `FirebaseAnalytics.getInstance(ctx)`. Returns null if
         * Firebase isn't on the classpath → adapter is silently disabled, app
         * works as if it had no Firebase provider.
         */
        @JvmStatic
        fun create(app: Application): FirebaseAdapter? {
            return try {
                val cls = Class.forName("com.google.firebase.analytics.FirebaseAnalytics")
                val m   = cls.getMethod("getInstance", android.content.Context::class.java)
                val inst = m.invoke(null, app) ?: return null
                FirebaseAdapter(cls, inst)
            } catch (e: ClassNotFoundException) {
                Log.i(TAG, "Firebase not on classpath → adapter no-op")
                null
            } catch (e: Throwable) {
                Log.w(TAG, "Firebase reflection setup failed: ${e.message}")
                null
            }
        }
    }
}
