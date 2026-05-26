package com.unitrack.sdk.firebase

import android.app.Application
import android.os.Bundle
import android.util.Log
import com.google.firebase.analytics.FirebaseAnalytics
import com.unitrack.sdk.providers.AnalyticsProvider

/**
 * Forwards every UniTrack event to Firebase Analytics.
 *
 * Prerequisites (standard Firebase Android setup, done by the app):
 *   • android/app/google-services.json
 *   • apply plugin 'com.google.gms.google-services' in the app module
 *
 *     UniTrack.addProvider(FirebaseProvider())
 *     UniTrack.initialize(app, UniTrackConfig(apiKey = ...))
 *
 * Firebase imposes strict naming rules (event/param names ≤40 chars,
 * alphanumeric + underscore, start with a letter; values String/Long/Double/
 * Bundle), so names and parameters are sanitized.
 */
class FirebaseProvider : AnalyticsProvider {

    private var fa: FirebaseAnalytics? = null

    override fun initialize(app: Application) {
        // FirebaseAnalytics.getInstance triggers Firebase auto-init from the
        // google-services.json-generated resources.
        fa = FirebaseAnalytics.getInstance(app)
        Log.i("UniTrackFirebase", "Firebase Analytics ready")
    }

    override fun track(name: String, properties: Map<String, Any?>) {
        fa?.logEvent(sanitizeName(name), toBundle(properties))
    }

    override fun setUser(userId: String?, traits: Map<String, Any?>) {
        fa?.setUserId(userId)
        for ((k, v) in traits) {
            fa?.setUserProperty(sanitizeName(k), v?.toString())
        }
    }

    override fun setScreen(name: String) {
        fa?.logEvent(FirebaseAnalytics.Event.SCREEN_VIEW, Bundle().apply {
            putString(FirebaseAnalytics.Param.SCREEN_NAME, name)
        })
    }

    // --- Firebase naming/value constraints ----------------------------------

    private val illegal = Regex("[^a-zA-Z0-9_]")

    private fun sanitizeName(name: String): String {
        var s = name.replace(illegal, "_")
        if (s.isNotEmpty() && !s.first().isLetter()) s = "e_$s"
        if (s.length > 40) s = s.substring(0, 40)
        return s
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
