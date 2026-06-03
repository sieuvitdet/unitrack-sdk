package com.unitrack.sdk

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Fetches the app's tracking config from the portal at startup (GET {portal}/config,
 * auth = api_key), so endpoints, providers, schemas and event-rewrite rules can
 * change WITHOUT rebuilding the app.
 *
 * Resilient: on success caches to SharedPreferences; on failure/timeout returns
 * the cached value or a built-in default. Dependency-free (HttpURLConnection +
 * org.json). The network call runs on a background thread; the callback is
 * invoked with a usable config.
 */
class UniTrackRemoteConfig(val raw: JSONObject) {

    val version: Int get() = raw.optInt("version", 0)
    val endpoint: String? get() = raw.optString("endpoint", null)
    val sdkConfig: JSONObject get() = raw.optJSONObject("sdk_config") ?: JSONObject()
    val snowplow: JSONObject get() = raw.optJSONObject("snowplow") ?: JSONObject()
    val firebase: JSONObject get() = raw.optJSONObject("firebase") ?: JSONObject()
    val rulesJson: org.json.JSONArray get() = raw.optJSONArray("rules") ?: org.json.JSONArray()

    /** Map config rules → SDK EventRule list. */
    fun toEventRules(): List<UniTrack.EventRule> {
        val out = mutableListOf<UniTrack.EventRule>()
        val arr = rulesJson
        for (i in 0 until arr.length()) {
            val r = arr.optJSONObject(i) ?: continue
            val add = mutableMapOf<String, Any?>()
            r.optJSONObject("add_props")?.let { ap ->
                for (k in ap.keys()) add[k] = ap.get(k)
            }
            out.add(UniTrack.EventRule(
                matchEvent = r.optString("match_event"),
                matchScreen = r.optString("match_screen", null),
                matchElementKey = r.optString("match_element_key", null),
                matchClassName = r.optString("match_class_name", null),
                toName = r.optString("to_name"),
                addProps = add,
            ))
        }
        return out
    }

    companion object {
        private const val PREFS = "unitrack"
        private const val KEY = "remote_config"

        /**
         * Fetch config in the background; [callback] is always called once with a
         * usable config (fresh, cached, or default). Never throws.
         *
         * [flavor] selects a per-build override block on the portal
         * (dev / staging / beta / production). Pass `BuildConfig.FLAVOR` from
         * the consuming app so debug/release builds get the right overrides
         * without juggling separate api_keys per flavor.
         */
        @JvmStatic
        @JvmOverloads
        fun fetch(ctx: Context, apiKey: String, configURL: String,
                  flavor: String? = null,
                  timeoutMs: Int = 3000,
                  callback: (UniTrackRemoteConfig) -> Unit) {
            // Append ?flavor=... onto the configured URL. URL.openConnection
            // handles existing query strings already on the URL (e.g. portal
            // setups that pass api_key as a query param).
            val urlStr = if (flavor.isNullOrBlank()) configURL
                else configURL + (if (configURL.contains('?')) "&" else "?") +
                    "flavor=" + java.net.URLEncoder.encode(flavor, "UTF-8")
            Thread {
                var result: UniTrackRemoteConfig? = null
                try {
                    val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        setRequestProperty("Authorization", "Bearer $apiKey")
                        // Header form too — useful when a CDN strips query strings.
                        if (!flavor.isNullOrBlank()) {
                            setRequestProperty("X-UniTrack-Flavor", flavor)
                        }
                        connectTimeout = timeoutMs
                        readTimeout = timeoutMs
                    }
                    if (conn.responseCode == 200) {
                        val body = conn.inputStream.bufferedReader().use { it.readText() }
                        val json = JSONObject(body)
                        cache(ctx, apiKey, body)
                        result = UniTrackRemoteConfig(json)
                    }
                    conn.disconnect()
                } catch (e: Exception) {
                    Log.w("UniTrackRemoteConfig", "fetch failed: ${e.message}")
                }
                callback(result ?: cached(ctx, apiKey) ?: builtinDefault())
            }.start()
        }

        private fun cache(ctx: Context, apiKey: String, body: String) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString("$KEY.$apiKey", body).apply()
        }

        private fun cached(ctx: Context, apiKey: String): UniTrackRemoteConfig? {
            val s = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString("$KEY.$apiKey", null) ?: return null
            return try { UniTrackRemoteConfig(JSONObject(s)) } catch (_: Exception) { null }
        }

        private fun builtinDefault(): UniTrackRemoteConfig = UniTrackRemoteConfig(JSONObject().apply {
            put("version", 0)
            put("endpoint", "https://mobix.asia/event-tracking-mobile/v1/events")
            put("sdk_config", JSONObject().apply {
                put("batchSize", 10); put("flushIntervalMs", 3000); put("autoCapture", true)
                put("trackScreens", true); put("trackTaps", true); put("trackNetwork", true)
                put("journeyCapture", true); put("sessionTimeoutMs", 1_800_000)
            })
            put("snowplow", JSONObject().put("enabled", false))
            put("firebase", JSONObject().put("enabled", false))
            put("rules", org.json.JSONArray())
        })
    }
}
