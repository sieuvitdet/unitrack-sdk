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

    /** Custom HTTP backends (Kibana / ELK / FPT internal). Portal là source of
     *  truth — app code chỉ seed cold-start, reconciler thay thế khi config về. */
    val httpProviders: org.json.JSONArray
        get() = raw.optJSONArray("http_providers") ?: org.json.JSONArray()

    /**
     * Reconcile registered HttpProviders với danh sách Portal config.
     *   - id mới → addHttpProvider
     *   - id cũ + enabled=false → removeProvider
     *   - id cũ + endpoint/format/headers đổi → remove + add lại
     * Idempotent — gọi lại không tạo provider trùng.
     */
    fun applyHttpProviders() {
        val desired = httpProviders
        val existingIds = UniTrack.registeredHttpProviderIds()

        // Build desired-id set (enabled only).
        val enabledIds = HashSet<String>()
        for (i in 0 until desired.length()) {
            val o = desired.optJSONObject(i) ?: continue
            val id = o.optString("id", "")
            if (id.isEmpty()) continue
            if (o.optBoolean("enabled", true)) enabledIds.add(id)
        }

        // Drop providers no longer wanted.
        for (id in existingIds) {
            if (!enabledIds.contains(id)) UniTrack.removeProvider(id)
        }

        // Add / replace from Portal.
        for (i in 0 until desired.length()) {
            val o = desired.optJSONObject(i) ?: continue
            if (!o.optBoolean("enabled", true)) continue
            val id       = o.optString("id", "")
            if (id.isEmpty()) continue
            val endpoint = o.optString("endpoint", "")
            if (endpoint.isEmpty()) continue
            val formatStr = o.optString("format", "json_single").lowercase()
            val format = when (formatStr) {
                "json_lines"   -> com.unitrack.sdk.providers.PayloadFormat.JSON_LINES
                "json_array"   -> com.unitrack.sdk.providers.PayloadFormat.JSON_ARRAY
                "elastic_bulk" -> com.unitrack.sdk.providers.PayloadFormat.ELASTIC_BULK
                else           -> com.unitrack.sdk.providers.PayloadFormat.JSON_SINGLE
            }
            val headersJson = o.optJSONObject("headers")
            val headers = HashMap<String, String>()
            if (headersJson != null) {
                val it = headersJson.keys()
                while (it.hasNext()) {
                    val k = it.next(); headers[k] = headersJson.optString(k, "")
                }
            }
            val batchSize = o.optInt("batch_size", 50)
            val flushMs   = o.optLong("flush_interval_ms", 30_000L)
            UniTrack.removeProvider(id)   // ensure clean replace
            UniTrack.addHttpProvider(id, endpoint, format, headers, batchSize, flushMs)
        }
    }

    /** Arbitrary key/value bag the portal serves to the app at runtime —
     *  the source of truth for [UniTrack.getRemoteValue]. App reads
     *  `feature_x`, `experiment_y` here; portal operator edits via the
     *  Config tab. Falls back to a Firebase RemoteConfig provider if a key
     *  is absent. */
    val customValues: JSONObject
        get() = sdkConfig.optJSONObject("custom_values") ?: JSONObject()

    companion object {
        private const val PREFS = "unitrack"
        private const val KEY = "remote_config"

        /** Most recent fetched config, or null before the first successful
         *  fetch. Updated by [fetch] on success + by [primeLatest] from the
         *  on-disk cache. The resolver consults this to answer
         *  [UniTrack.getRemoteValue] without threading apiKey through. */
        @Volatile
        @JvmStatic
        var latest: UniTrackRemoteConfig? = null
            private set

        /** Prime [latest] from the on-disk cache. Call once at app launch
         *  (before the async fetch returns) so the very first
         *  getRemoteValue() query already has portal values to consult. */
        @JvmStatic
        fun primeLatest(ctx: Context, apiKey: String) {
            if (latest == null) latest = cached(ctx, apiKey)
        }

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
                        latest = result   // process-wide snapshot for getRemoteValue
                        // Portal là source of truth cho HttpProviders — reconcile
                        // mỗi lần config về (cold start, SSE push, foreground
                        // refetch). App không cần nhớ gọi tay.
                        try { result.applyHttpProviders() } catch (e: Throwable) {
                            Log.w("UniTrackRemoteConfig",
                                  "applyHttpProviders failed: ${e.message}")
                        }
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
        })
    }
}
