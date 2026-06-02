package com.unitrack.sdk

import android.app.Application
import android.content.Context
import android.util.Log
import com.unitrack.sdk.bridge.NativeBridge
import com.unitrack.sdk.lifecycle.ActivityTracker
import com.unitrack.sdk.lifecycle.AppLifecycleObserver
import com.unitrack.sdk.network.OkHttpTracker
import com.unitrack.sdk.providers.AnalyticsProvider
import com.unitrack.sdk.ui.ClickTracker
import org.json.JSONObject

/**
 * Public entry point. Partners call:
 *
 *     UniTrack.initialize(application, UniTrackConfig(apiKey = "..."))
 *
 * All other tracking is automatic.
 */
object UniTrack {

    @Volatile
    private var initialized = false

    // Registered third-party providers (Snowplow, Firebase, …). Every event is
    // forwarded to each one. Empty by default — core has zero such dependencies.
    private val providers = mutableListOf<AnalyticsProvider>()
    private var appRef: Application? = null

    /**
     * Per-event Log of what flows through UniTrack/Snowplow/Firebase. Default ON
     * so integrators see traffic immediately while wiring the SDK up; flip to OFF
     * (UniTrack.verboseLogging = false) before shipping a release build.
     */
    @JvmField
    var verboseLogging: Boolean = true

    /**
     * Provider/helper code uses this instead of Log.i directly so the integrator
     * can mute every log line with one flag. Format mirrors NSLog on iOS for
     * cross-platform parity.
     */
    @JvmStatic
    fun log(tag: String, msg: String) {
        if (verboseLogging) android.util.Log.i(tag, msg)
    }

    /** Register a provider to also receive every event. Call BEFORE initialize();
     *  if called afterwards, the provider is initialized immediately. */
    @JvmStatic
    fun addProvider(provider: AnalyticsProvider) {
        providers.add(provider)
        appRef?.let { provider.initialize(it) }  // already initialized → bring up now
    }

    // Run [action] against every provider, isolating failures so one bad
    // provider never breaks the main pipeline.
    private inline fun forEachProvider(action: (AnalyticsProvider) -> Unit) {
        for (p in providers) {
            try { action(p) } catch (e: Throwable) {
                android.util.Log.w("UniTrack", "provider forward failed: ${e.message}")
            }
        }
    }

    @JvmStatic
    fun initialize(app: Application, config: UniTrackConfig) {
        if (initialized) {
            android.util.Log.w("UniTrack", "already initialized")
            return
        }

        // Load native lib + open core context.
        NativeBridge.load()
        val cfgJson = buildConfigJson(app, config)
        NativeBridge.init(config.apiKey, cfgJson, PLATFORM_ANDROID)

        // Attach device/app metadata to every event (model, OS, app version,
        // network type, root status, …) — collected once here.
        NativeBridge.setDeviceInfo(DeviceInfo.json(app))

        // Mark initialized BEFORE installing auto-capture: install() may emit a
        // setScreen for the already-resumed activity (when bootstrap is async),
        // and a guard checking `initialized` would silently drop that first
        // screen — losing every screen_view + the start-of-journey marker.
        initialized = true
        appRef = app

        if (config.autoCapture) {
            if (config.trackScreens) ActivityTracker.install(app)
            if (config.trackTaps)    ClickTracker.install(app)
            if (config.trackNetwork) OkHttpTracker.install()
            AppLifecycleObserver.install(app)
        }

        NativeBridge.logAppStart(0L)

        // Bring up any providers registered before initialize().
        forEachProvider { it.initialize(app) }

        // Pop any crash the core recovered at init() time (from crash-pending.json).
        // Core already enqueued it to the offline queue (→ portal HTTP); this
        // re-emits through provider track() so Snowplow + Firebase see the
        // recovered crash through their own paths (matches iOS behavior).
        val recoveredJson = NativeBridge.popRecoveredCrash()
        if (recoveredJson.isNotEmpty()) {
            try {
                val obj = JSONObject(recoveredJson)
                val props = HashMap<String, Any?>(obj.length() + 1)
                obj.keys().forEach { k -> props[k] = obj.opt(k) }
                props["recovered_on_launch"] = true
                Log.i("UniTrack", "fan-out recovered crash to ${providers.size} provider(s)")
                forEachProvider { it.track("crash", props) }
            } catch (e: Throwable) {
                Log.w("UniTrack", "popRecoveredCrash: parse failed: ${e.message}")
            }
        }
    }

    @JvmStatic
    fun identify(userId: String, traits: Map<String, Any?> = emptyMap()) {
        forEachProvider { it.setUser(userId, traits) }
        if (initialized) NativeBridge.identify(userId, JSONObject(traits).toString())
    }

    @JvmStatic
    fun reset() {
        forEachProvider { it.setUser(null, emptyMap()) }
        if (initialized) NativeBridge.reset()
    }

    // Event rewrite rules (Phase 2 — config-driven). A matching rule renames an
    // auto-captured event into a business event + merges props at this chokepoint.
    // NOTE: tap & screen_view flow through track() so they're covered; network
    // events bypass track() (NativeBridge.logNetwork) so rules don't reach them.
    data class EventRule(
        val matchEvent: String,
        val matchScreen: String?,
        val matchElementKey: String?,
        /** View class name (target.javaClass.name from ClickTracker) — useful
         *  when label text is dynamic / localized but class is stable. */
        val matchClassName: String? = null,
        val toName: String,
        val addProps: Map<String, Any?> = emptyMap(),
    )
    private val eventRules = mutableListOf<EventRule>()

    @JvmStatic
    fun setEventRules(rules: List<EventRule>) {
        eventRules.clear(); eventRules.addAll(rules)
    }

    // ── W3C distributed tracing ────────────────────────────────────────────
    //
    // Apps install UniTrackTracingInterceptor on their OkHttpClient (and/or
    // wrap HttpURLConnection manually). When enabled, the interceptor mints a
    // (trace_id, span_id) per outbound request and adds `traceparent` for
    // hosts on the allowlist. allowlistHosts is fail-closed: empty list ⇒
    // never inject (so `traceparent` doesn't leak to Firebase/Maps/CDNs).
    @Volatile private var tracingEnabled  = false
    @Volatile private var tracingHeader   = "traceparent"
    @Volatile private var tracingAllow    = emptyList<String>()
    @Volatile private var tracingSampled  = true

    @JvmStatic
    @JvmOverloads
    fun setTracing(enabled: Boolean,
                   headerName: String = "traceparent",
                   allowlistHosts: List<String> = emptyList(),
                   sampled: Boolean = true) {
        tracingEnabled = enabled
        tracingHeader  = if (headerName.isBlank()) "traceparent" else headerName
        tracingAllow   = allowlistHosts
        tracingSampled = sampled
    }

    // Snapshot read by the OkHttp interceptor without locking — volatile reads
    // give enough safety since each field updates independently and the
    // interceptor tolerates a torn read (worst case: one request uses the new
    // header name with the old allowlist for a microsecond).
    internal fun tracingSnapshot(): TracingSnapshot =
        TracingSnapshot(tracingEnabled, tracingHeader, tracingAllow, tracingSampled)

    internal data class TracingSnapshot(
        val enabled: Boolean, val headerName: String,
        val allowlist: List<String>, val sampled: Boolean,
    )

    /** Decide if `host` should receive a `traceparent` header. See setTracing(). */
    internal fun shouldInjectTrace(host: String?, allowlist: List<String>): Boolean {
        if (host.isNullOrEmpty() || allowlist.isEmpty()) return false
        val h = host.lowercase()
        for (raw in allowlist) {
            val pat = raw.lowercase()
            if (pat == h) return true
            if (pat.startsWith("*.")) {
                val suffix = pat.substring(1)               // ".mobix.asia"
                if (h.endsWith(suffix) || h == suffix.substring(1)) return true
            }
        }
        return false
    }

    private fun applyRules(event: String, props: Map<String, Any?>): Pair<String, Map<String, Any?>>? {
        val screen = (props["screen"] ?: props["screen_name"]) as? String
        val elem = props["element_key"] as? String
        val cls  = props["class_name"] as? String
        for (r in eventRules) {
            if (r.matchEvent != event) continue
            if (r.matchScreen != null && r.matchScreen != screen) continue
            if (r.matchElementKey != null && r.matchElementKey != elem) continue
            if (r.matchClassName != null && r.matchClassName != cls) continue
            return r.toName to (props + r.addProps)
        }
        return null
    }

    @JvmStatic
    @JvmOverloads
    fun track(event: String, properties: Map<String, Any?> = emptyMap()) {
        var name = event
        var props = properties
        applyRules(event, properties)?.let { (n, p) ->
            name = n; props = p
            log("UniTrack", "rule rewrite: $event → $n")
        }
        if (verboseLogging) {
            val provNames = providers.joinToString(",") { it::class.simpleName ?: "?" }
            log("UniTrack", "track event=\"$name\" props=${JSONObject(props)} → providers=[${if (provNames.isEmpty()) "(none)" else provNames}]")
        }
        forEachProvider { it.track(name, props) }
        // Guard the native call: a tracking call can arrive before initialize()
        // finishes (e.g. RN's navigation tracker fires setScreen on first render
        // while initialize() is still in-flight). Calling JNI before
        // System.loadLibrary ran throws UnsatisfiedLinkError, so skip it.
        if (initialized) NativeBridge.track(name, JSONObject(props).toString())
    }

    @JvmStatic
    fun setScreen(name: String) {
        forEachProvider { it.setScreen(name) }
        if (initialized) NativeBridge.setScreen(name)
    }

    // --- semantic event helpers (Phase 3) ----------------------------------
    // notificationId + data added in audit-fix phase 3: FCM/local notifications
    // carry routing keys (deeplink, campaign_id) in the data payload that the
    // earlier short signature dropped on the floor.
    @JvmStatic @JvmOverloads
    fun trackNotification(state: String, action: String = "received",
                          title: String? = null, body: String? = null,
                          notificationId: String? = null,
                          data: Map<String, Any?>? = null) {
        val p = mutableMapOf<String, Any?>("state" to state, "action" to action)
        title?.let { p["title"] = it }
        body?.let { p["body"] = it }
        notificationId?.takeIf { it.isNotEmpty() }?.let { p["notification_id"] = it }
        data?.takeIf { it.isNotEmpty() }?.let { p["data"] = it }
        track("notification", p)
    }

    @JvmStatic
    fun trackWebViewOpen(url: String) = track("webview_open", mapOf("url" to hostPath(url)))

    // The SDK boot time, used to flag deeplinks that fired within the cold-
    // start window. android.os.SystemClock.elapsedRealtime() avoids wall-clock
    // jumps; same source UniTrackDeeplinks reads.
    internal val bootElapsedMs: Long = android.os.SystemClock.elapsedRealtime()
    internal val coldDeeplinkWindowMs: Long = 5_000L

    /// A deeplink / universal link opened the app or a screen.
    /// Adds scheme/host/path/query separately + is_cold flag (true when this
    /// fires within 5s of SDK boot = the link launched the app).
    @JvmStatic @JvmOverloads
    fun trackDeeplink(url: String, source: String? = null) {
        val p = mutableMapOf<String, Any?>("url" to url)
        runCatching {
            val u = android.net.Uri.parse(url)
            u.scheme?.takeIf { it.isNotEmpty() }?.let { p["scheme"] = it }
            u.host?.takeIf { it.isNotEmpty() }?.let { p["host"] = it }
            u.path?.takeIf { it.isNotEmpty() }?.let { p["path"] = it }
            u.query?.takeIf { it.isNotEmpty() }?.let { p["query"] = it }
        }
        source?.let { p["source"] = it }
        val elapsed = android.os.SystemClock.elapsedRealtime() - bootElapsedMs
        p["is_cold"] = elapsed in 0..coldDeeplinkWindowMs
        track("deeplink", p)
    }

    @JvmStatic
    fun trackThirdPartyOpen(name: String) = track("third_party_open", mapOf("target" to name))

    private fun hostPath(url: String): String = runCatching {
        val u = android.net.Uri.parse(url)
        if (u.scheme != null && u.host != null) "${u.scheme}://${u.host}${u.path ?: ""}" else (u.path ?: url)
    }.getOrDefault(url)

    @JvmStatic
    fun flush() { if (initialized) NativeBridge.flush() }

    // Hosts/substrings excluded from network auto-capture. Providers add their
    // own collector/upload URLs here so the SDK never captures-and-re-forwards
    // its own analytics traffic into an amplifying loop.
    @Volatile
    internal var networkExclusions: List<String> = emptyList()
    private val exclusionLock = Object()

    /**
     * Exclude a URL (matched by substring, e.g. a host) from network
     * auto-capture. Providers (FirebaseProvider, SnowplowProvider) call this
     * for their own collector/upload URLs to break the capture-forward-capture
     * cycle.
     */
    @JvmStatic
    fun excludeFromNetworkCapture(urlContaining: String) {
        synchronized(exclusionLock) {
            if (urlContaining.isEmpty()) return
            if (networkExclusions.contains(urlContaining)) return
            networkExclusions = networkExclusions + urlContaining
        }
    }

    @JvmStatic
    fun setEnabled(enabled: Boolean) { if (initialized) NativeBridge.setEnabled(enabled) }

    private fun buildConfigJson(ctx: Context, c: UniTrackConfig): String {
        val obj = JSONObject()
        c.endpoint?.let { obj.put("endpoint", it) }
        obj.put("batch_size",        c.batchSize)
        obj.put("flush_interval_ms", c.flushIntervalMs)
        obj.put("sampling_rate",     c.samplingRate)
        obj.put("auto_capture",      c.autoCapture)
        obj.put("journey_capture",   c.journeyCapture)
        obj.put("session_timeout_ms", c.sessionTimeoutMs)
        obj.put("screen_lifecycle",   c.screenLifecycle)
        obj.put("screen_start_event", c.screenStartEvent)
        obj.put("screen_end_event",   c.screenEndEvent)
        obj.put("db_path",
                ctx.filesDir.absolutePath + "/unitrack_queue.db")
        return obj.toString()
    }

    internal const val PLATFORM_ANDROID = 2
}
