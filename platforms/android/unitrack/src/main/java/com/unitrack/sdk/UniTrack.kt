package com.unitrack.sdk

import android.app.Application
import android.content.Context
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
        val toName: String,
        val addProps: Map<String, Any?> = emptyMap(),
    )
    private val eventRules = mutableListOf<EventRule>()

    @JvmStatic
    fun setEventRules(rules: List<EventRule>) {
        eventRules.clear(); eventRules.addAll(rules)
    }

    private fun applyRules(event: String, props: Map<String, Any?>): Pair<String, Map<String, Any?>>? {
        val screen = (props["screen"] ?: props["screen_name"]) as? String
        val elem = props["element_key"] as? String
        for (r in eventRules) {
            if (r.matchEvent != event) continue
            if (r.matchScreen != null && r.matchScreen != screen) continue
            if (r.matchElementKey != null && r.matchElementKey != elem) continue
            return r.toName to (props + r.addProps)
        }
        return null
    }

    @JvmStatic
    @JvmOverloads
    fun track(event: String, properties: Map<String, Any?> = emptyMap()) {
        var name = event
        var props = properties
        applyRules(event, properties)?.let { (n, p) -> name = n; props = p }
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
    @JvmStatic @JvmOverloads
    fun trackNotification(state: String, action: String = "received",
                          title: String? = null, body: String? = null) {
        val p = mutableMapOf<String, Any?>("state" to state, "action" to action)
        title?.let { p["title"] = it }; body?.let { p["body"] = it }
        track("notification", p)
    }

    @JvmStatic
    fun trackWebViewOpen(url: String) = track("webview_open", mapOf("url" to hostPath(url)))

    @JvmStatic @JvmOverloads
    fun trackDeeplink(url: String, source: String? = null) {
        val p = mutableMapOf<String, Any?>("url" to hostPath(url))
        source?.let { p["source"] = it }
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
