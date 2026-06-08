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
    // Internal so RemoteValueProvider lookup can iterate the list.
    internal val providers = mutableListOf<AnalyticsProvider>()
    private var appRef: Application? = null

    // Device bag (model, OS, app version, network_*) the core stamps onto
    // every event. Snapshot at init so providers (Snowplow) can build their
    // own application_context entity from the same source the wire payload
    // uses, without re-running platform queries.
    internal var cachedDeviceBag: Map<String, Any?> = emptyMap()

    /** Device/app metadata bag captured at init (platform, app_version,
     *  network_*, device_*). SnowplowProvider attaches this as the
     *  `application_context` entity. Empty before initialize(). */
    @JvmStatic
    fun applicationContext(): Map<String, Any?> = cachedDeviceBag

    /** Parse the JSON the core consumes back into a Kotlin map. */
    private fun parseDeviceBag(json: String): Map<String, Any?> = runCatching {
        val o = org.json.JSONObject(json)
        buildMap {
            o.keys().forEach { k -> put(k, o.opt(k)) }
        }
    }.getOrDefault(emptyMap())

    // ── Remote value resolver (iOS parity) ─────────────────────────────────
    //
    // Resolve runtime values in order:
    //   1. Portal sdk_config.custom_values[key] (operator-edited)
    //   2. Any registered RemoteValueProvider (FirebaseProvider conforms)
    //   3. Caller's defaultValue
    //
    // Portal first lets ops override Firebase RC without touching the app
    // or Firebase Console — useful for incident response + incremental
    // migration off Firebase.

    @JvmStatic
    fun getRemoteString(key: String, default: String): String {
        portalRemoteValue<String>(key)?.let { return it }
        providers.forEach { p ->
            if (p is RemoteValueProvider) p.getRemoteValue<String>(key)?.let { return it }
        }
        return default
    }

    @JvmStatic
    fun getRemoteInt(key: String, default: Int): Int {
        portalRemoteValue<Int>(key)?.let { return it }
        providers.forEach { p ->
            if (p is RemoteValueProvider) p.getRemoteValue<Int>(key)?.let { return it }
        }
        return default
    }

    @JvmStatic
    fun getRemoteLong(key: String, default: Long): Long {
        portalRemoteValue<Long>(key)?.let { return it }
        providers.forEach { p ->
            if (p is RemoteValueProvider) p.getRemoteValue<Long>(key)?.let { return it }
        }
        return default
    }

    @JvmStatic
    fun getRemoteDouble(key: String, default: Double): Double {
        portalRemoteValue<Double>(key)?.let { return it }
        providers.forEach { p ->
            if (p is RemoteValueProvider) p.getRemoteValue<Double>(key)?.let { return it }
        }
        return default
    }

    @JvmStatic
    fun getRemoteBoolean(key: String, default: Boolean): Boolean {
        portalRemoteValue<Boolean>(key)?.let { return it }
        providers.forEach { p ->
            if (p is RemoteValueProvider) p.getRemoteValue<Boolean>(key)?.let { return it }
        }
        return default
    }

    /** Pull [key] out of [UniTrackRemoteConfig.latest].customValues and
     *  coerce to T. Returns null if no fetch happened yet or the key is
     *  missing or the value can't be cast (config bug, caller falls back
     *  to default). */
    @Suppress("UNCHECKED_CAST")
    private inline fun <reified T> portalRemoteValue(key: String): T? {
        val bag = UniTrackRemoteConfig.latest?.customValues ?: return null
        if (!bag.has(key)) return null
        val raw = bag.opt(key) ?: return null
        return when (T::class) {
            String::class  -> raw.toString() as? T
            Int::class     -> (raw as? Number)?.toInt() as? T
            Long::class    -> (raw as? Number)?.toLong() as? T
            Double::class  -> (raw as? Number)?.toDouble() as? T
            Boolean::class -> when (raw) {
                is Boolean -> raw as T
                is String  -> raw.toBooleanStrictOrNull() as? T
                is Number  -> (raw.toInt() != 0) as T
                else -> null
            }
            else -> null
        }
    }

    /**
     * Per-event Log of what flows through UniTrack/Snowplow/Firebase. Default ON
     * so integrators see traffic immediately while wiring the SDK up; flip to OFF
     * (UniTrack.verboseLogging = false) before shipping a release build.
     */
    @JvmField
    var verboseLogging: Boolean = true

    /**
     * Resolved event name fired by ActivityTracker's fragment lifecycle hook
     * when a screen is created + first becomes interactive (= "load_ms" window
     * between onFragmentCreated and onFragmentResumed). Mirrors the iOS
     * swizzler's `screen_load_completed` event. Initialised from
     * `config.screenLoadEvent` on initialize(); the portal `sdk_config.screen_load_event`
     * key can rename it without an app rebuild.
     */
    @JvmField
    var screenLoadEventName: String = "screen_load_completed"

    // ─── App lifecycle callbacks (app-facing) ────────────────────────────
    // Apps register a listener to know when the SDK observes a foreground or
    // background transition — typically used to fire app-level events that
    // the core itself doesn't model (e.g. `session_ended` semantics that
    // depend on app product logic). The SDK already emits app_foreground /
    // app_background to the core's offline queue; these callbacks are for
    // additional app-side tracking on top of that.
    fun interface LifecycleListener {
        fun onTransition(toForeground: Boolean)
    }
    private val lifecycleListeners = mutableListOf<LifecycleListener>()

    @JvmStatic
    fun addLifecycleListener(listener: LifecycleListener) {
        lifecycleListeners.add(listener)
    }

    @JvmStatic
    internal fun dispatchForegroundCallback() {
        for (l in lifecycleListeners) {
            try { l.onTransition(true) }
            catch (e: Throwable) { android.util.Log.w("UniTrack", "lifecycle listener: ${e.message}") }
        }
    }

    @JvmStatic
    internal fun dispatchBackgroundCallback() {
        for (l in lifecycleListeners) {
            try { l.onTransition(false) }
            catch (e: Throwable) { android.util.Log.w("UniTrack", "lifecycle listener: ${e.message}") }
        }
    }

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

        // Wire taxonomy override into the swizzler bridge before installing the
        // trackers below — they read this static at fire time.
        if (config.screenLoadEvent.isNotEmpty()) {
            screenLoadEventName = config.screenLoadEvent
        }

        // Load native lib + open core context.
        NativeBridge.load()
        val cfgJson = buildConfigJson(app, config)
        NativeBridge.init(config.apiKey, cfgJson, PLATFORM_ANDROID)

        // Attach device/app metadata to every event (model, OS, app version,
        // network type, root status, …) — collected once here. Snapshot is
        // kept on the singleton so providers building their own context
        // entities (vd Snowplow application_context) read the same source
        // the wire payload uses, without re-running the platform queries.
        val deviceJson = DeviceInfo.json(app)
        NativeBridge.setDeviceInfo(deviceJson)
        cachedDeviceBag = parseDeviceBag(deviceJson)

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
                if (providers.isNotEmpty()) {
                    Log.i("UniTrack", "fan-out recovered crash to ${providers.size} provider(s)")
                    forEachProvider { it.track("crash", props) }
                }
                // Stash the JSON for the Flutter plugin to forward up to Dart
                // (Flutter apps may host Dart-side providers that the native
                // forEachProvider loop above doesn't reach). Single-shot.
                pendingRecoveredCrashJsonForFlutter = JSONObject(props as Map<*, *>).toString()
            } catch (e: Throwable) {
                Log.w("UniTrack", "popRecoveredCrash: parse failed: ${e.message}")
            }
        }
    }

    /// Single-shot drain for the Flutter MethodChannel bridge. Returns the
    /// JSON-encoded recovered crash props (with `recovered_on_launch=true`)
    /// captured during initialize(), or "" if nothing to forward. Native apps
    /// (pure Android Kotlin/Java) don't need this; it exists so the Flutter
    /// plugin can forward the same payload up the channel to Dart providers.
    @Volatile private var pendingRecoveredCrashJsonForFlutter: String? = null
    @JvmStatic
    fun takeRecoveredCrashJsonForFlutter(): String {
        val out = pendingRecoveredCrashJsonForFlutter ?: return ""
        pendingRecoveredCrashJsonForFlutter = null
        return out
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

    // ── Session API (iOS parity) ───────────────────────────────────────────
    //
    // SessionManager in core C++ persists session_id + session_index +
    // previous_session_id across launches via session.json. These wrappers
    // expose them so apps don't maintain a duplicate (resetting-to-0)
    // counter on the binding side.

    /** UUID of the active session. Empty before initialize(). Persists across
     *  app restarts within the 30-min inactivity timeout. */
    @JvmStatic
    fun currentSessionId(): String =
        if (initialized) NativeBridge.currentSessionId() else ""

    /** Lifetime session counter. 1 on first install, +1 per rotation
     *  (timeout or manual). Persists across app restarts. Returns 0 before
     *  initialize(). */
    @JvmStatic
    fun sessionIndex(): Long =
        if (initialized) NativeBridge.sessionIndex() else 0L

    /** UUID of the previous (just-closed) session — empty on the very first
     *  session after install. Pair with sessionIndex() in session_started
     *  payloads so backends can chain consecutive sessions. */
    @JvmStatic
    fun previousSessionId(): String =
        if (initialized) NativeBridge.previousSessionId() else ""

    /** Force a session rotation now. Bumps sessionIndex(), mints a new
     *  currentSessionId(), records the just-closed UUID as previousSessionId().
     *  Use on logout / switch-account / new-conversation boundaries when the
     *  timeout-based rotation isn't enough. */
    @JvmStatic
    fun rotateSession() {
        if (initialized) NativeBridge.rotateSession()
    }

    // Session-stat sidebag — counters the binding tracks so session_ended
    // payloads can carry screen_count + had_error + had_crash without the
    // app having to keep its own state. Reset via resetSessionStats() at
    // the start of each session.
    @Volatile private var sessionScreenCount: Int = 0
    @Volatile private var sessionHadError: Boolean = false
    @Volatile private var sessionHadCrash: Boolean = false

    @JvmStatic fun sessionScreenCount(): Int  = sessionScreenCount
    @JvmStatic fun sessionHadError(): Boolean = sessionHadError
    @JvmStatic fun sessionHadCrash(): Boolean = sessionHadCrash

    @JvmStatic fun incrementScreenCount() { sessionScreenCount += 1 }
    @JvmStatic fun markSessionError()     { sessionHadError = true }
    @JvmStatic fun markSessionCrash()     { sessionHadCrash = true }

    /** Reset the per-session counters — typically called from the app's own
     *  session_started handler after a rotation. */
    @JvmStatic
    fun resetSessionStats() {
        sessionScreenCount = 0
        sessionHadError = false
        sessionHadCrash = false
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

    @JvmStatic
    @JvmOverloads
    fun track(event: String, properties: Map<String, Any?> = emptyMap()) {
        val name = event
        val props = properties
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
