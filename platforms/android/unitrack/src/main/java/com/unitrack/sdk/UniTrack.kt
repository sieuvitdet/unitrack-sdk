package com.unitrack.sdk

import android.app.Application
import android.content.Context
import android.util.Log
import com.unitrack.sdk.bridge.NativeBridge
import com.unitrack.sdk.lifecycle.ActivityTracker
import com.unitrack.sdk.lifecycle.AppLifecycleObserver
import com.unitrack.sdk.network.OkHttpTracker
import com.unitrack.sdk.providers.AnalyticsProvider
import com.unitrack.sdk.providers.PendingQueue
import com.unitrack.sdk.providers.ProviderResult
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

    @Volatile
    private var headlessLaunch = false

    /**
     * True khi process này khởi động KHÔNG do user mở app (FCM đánh thức để
     * xử lý push, WorkManager job, boot receiver). Core đã tự bỏ qua việc
     * rotate session ở trường hợp này; host đọc cờ để bỏ qua luôn các event
     * mang nghĩa "user bắt đầu phiên":
     *
     *     FSDKTracking.bootstrap(app) {
     *         if (!UniTrack.isHeadlessLaunch()) FSDKTracking.sessionStarted()
     *     }
     *
     * Luôn false trước initialize().
     */
    @JvmStatic
    fun isHeadlessLaunch(): Boolean = headlessLaunch

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

    // Last screen seen by setScreen(), used so the binding can fan out a
    // matching screen_exited/screen_viewed pair into providers (Snowplow,
    // Firebase) in lockstep with what the C++ core enqueues into its HTTP
    // queue. Both paths read the same screen_start/end_event wire names so
    // the portal log + the Snowplow collector see identical transitions.
    private val screenLock = Any()
    private var lastScreen: String? = null
    private var lastScreenAtMs: Long = 0L

    /**
     * Screen name of the most recent setScreen() call, or null at cold
     * start. Callers should read this BEFORE invoking setScreen() when
     * they need the outgoing screen (e.g. ActivityTracker stamping
     * `previous_screen_name` on screen_load_completed).
     */
    @JvmStatic
    fun previousScreenName(): String? {
        synchronized(screenLock) { return lastScreen }
    }
    // ponytail: default is the BUSINESS name, never the schema kind.
    // "screen_view" is the Snowplow convention kind (the iglu schema parent
    // shared by screen_viewed + screen_exited + screen_load_completed) — it
    // must never reach the wire as an event_action value. Config load is async
    // in most hosts, so any screen firing before initialize() completes ships
    // whatever is here. Parity with iOS UniTrack.screenStartEventName.
    private var screenStartEventName: String = "screen_viewed"
    private var screenEndEventName:   String = "screen_exited"
    private var screenLifecycleEnabled: Boolean = true

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
    //   2. Any registered RemoteValueProvider (FirebaseAdapter conforms)
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
        fireForegroundIfThrottleElapsed()
    }

    // App-supplied closure invoked once each time the app comes back to
    // foreground AND the throttle window has elapsed (default 5 min). Used by
    // the app integration layer (vd FSDKTracking) to re-fetch portal remote
    // config without baking the fetch URL/api_key into the SDK core. iOS
    // parity — UniTrack.onAppForeground { ... }.
    @Volatile private var appForegroundHandler: (() -> Unit)? = null
    @Volatile private var foregroundThrottleMs: Long = 5L * 60L * 1000L
    @Volatile private var lastForegroundCallbackAt: Long = 0L

    /**
     * Register a closure invoked when the app comes back to foreground. Used
     * by host integrations to refresh portal remote config (or any other
     * startup-bound resource) without baking the fetch into the SDK core.
     *
     * Throttled by `throttleMs` (default 5 min). The first foreground after
     * `initialize()` does NOT fire (cold start already fetched). Subsequent
     * onActivityStarted 0→1 transitions trigger only when at least
     * `throttleMs` have passed since the previous callback.
     *
     * Pass `handler = null` to clear.
     */
    @JvmStatic
    @JvmOverloads
    fun onAppForeground(throttleMs: Long = 5L * 60L * 1000L, handler: (() -> Unit)?) {
        appForegroundHandler = handler
        foregroundThrottleMs = throttleMs
        lastForegroundCallbackAt = System.currentTimeMillis()  // seed so cold start doesn't fire
    }

    private fun fireForegroundIfThrottleElapsed() {
        val handler = appForegroundHandler ?: return
        val now = System.currentTimeMillis()
        if (now - lastForegroundCallbackAt < foregroundThrottleMs) return
        lastForegroundCallbackAt = now
        try { handler() }
        catch (e: Throwable) { android.util.Log.w("UniTrack", "onAppForeground handler: ${e.message}") }
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

    /** Drop every registered provider. Call before re-adding providers when
     *  the host re-reads portal config (vd flavor switch, SSE-driven realtime
     *  refresh). Without it, a re-init would leave the OLD SnowplowProvider /
     *  FirebaseAdapter in the fan-out list alongside the new one and every
     *  event would land twice — once at the old endpoint, once at the new
     *  one. Mirrors iOS UniTrack.removeAllProviders(). */
    @JvmStatic
    fun removeAllProviders() {
        providers.clear()
    }

    /** Remove a single registered provider by identity. */
    @JvmStatic
    fun removeProvider(provider: AnalyticsProvider) {
        providers.removeAll { it === provider }
    }

    /** Remove a provider by its providerId. Used by the remote-config
     *  reconciler to drop providers no longer in Portal config + replace
     *  providers whose endpoint/headers/format changed (remove + add).
     *  No-op if no match — idempotent. */
    @JvmStatic
    fun removeProvider(id: String) {
        providers.removeAll { it.providerId == id }
    }

    /** IDs of every registered HttpProvider — used by the remote-config
     *  reconciler (UniTrackRemoteConfig.applyHttpProviders) to compute the
     *  diff against Portal's desired list. Non-HttpProvider providers
     *  (Snowplow, Firebase, app-supplied) are excluded. */
    @JvmStatic
    fun registeredHttpProviderIds(): List<String> =
        providers.filterIsInstance<com.unitrack.sdk.providers.HttpProvider>()
                 .map { it.providerId }

    /** Hot-reload the screen-lifecycle wire-event names without forcing the
     *  host to call UniTrack.initialize again (which is no-op after the
     *  first call). The provider fan-out path reads these caches AT FIRE
     *  TIME, so post-refresh events land under the new names on Snowplow /
     *  Firebase. The C++ core's own copies (HTTP queue) keep cold-start
     *  values — fully resetting the core mid-flight risks dropping events.
     *
     *  Pass null for any field to keep its current value. Empty string ""
     *  resets to the default ("screen_viewed" / "screen_exited" /
     *  "screen_load_completed").
     *  Mirrors iOS UniTrack.applyHotConfig(...). */
    @JvmStatic
    @JvmOverloads
    fun applyHotConfig(screenStartEvent: String? = null,
                       screenEndEvent:   String? = null,
                       screenLoadEvent:  String? = null) {
        screenStartEvent?.let {
            screenStartEventName = it.ifEmpty { "screen_viewed" }
        }
        screenEndEvent?.let {
            screenEndEventName = it.ifEmpty { "screen_exited" }
        }
        screenLoadEvent?.let {
            screenLoadEventName = it.ifEmpty { "screen_load_completed" }
        }
        android.util.Log.i("UniTrack",
            "hot-config screen events → start=$screenStartEventName end=$screenEndEventName load=$screenLoadEventName")
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

    @Volatile private var pendingQueue: PendingQueue? = null
    @Volatile private var pendingWorker: Thread? = null

    /**
     * Ack-aware fan-out. Calls `provider.send()` on every registered provider:
     *   - SUCCESS → done
     *   - RETRY   → enqueue into PendingQueue (per-provider bitmask) for retry
     *   - DROP    → log and discard for that provider only
     *
     * Existing providers (Snowplow, Firebase) use the default `send()` impl
     * which calls `track()` and returns SUCCESS → zero behaviour change for
     * them. Custom HTTP providers (HttpProvider) override `send()` so we lo
     * offline retry for any backend that doesn't bring its own SDK queue.
     */
    private fun dispatchToProviders(name: String, props: Map<String, Any?>) {
        val retryIds = mutableListOf<String>()
        for (p in providers) {
            val r = try { p.send(name, props) } catch (e: Throwable) {
                android.util.Log.w("UniTrack", "provider send failed: ${e.message}")
                ProviderResult.DROP
            }
            when (r) {
                ProviderResult.SUCCESS -> {}
                ProviderResult.RETRY   -> retryIds.add(p.providerId)
                ProviderResult.DROP    -> {
                    android.util.Log.w("UniTrack", "provider ${p.providerId} dropped event \"$name\"")
                }
            }
        }
        if (retryIds.isNotEmpty()) {
            pendingQueue?.enqueue(name, props, retryIds)
            wakePendingWorker()
        }
    }

    private fun ensurePendingQueue(app: Application) {
        if (pendingQueue == null) {
            synchronized(this) {
                if (pendingQueue == null) {
                    pendingQueue = PendingQueue(app)
                    startPendingWorker()
                }
            }
        }
    }

    private fun startPendingWorker() {
        if (pendingWorker != null) return
        val t = Thread({
            while (initialized) {
                try {
                    Thread.sleep(2_000)
                    val q = pendingQueue ?: continue
                    q.trim()
                    val batch = q.peek(50)
                    if (batch.isEmpty()) continue
                    for (p in batch) {
                        val successful = mutableListOf<String>()
                        val retrying   = mutableListOf<String>()
                        val dropped    = mutableListOf<String>()
                        var mask = p.pendingMask
                        for (provider in providers) {
                            val bit = 1L shl q.bitFor(provider.providerId)
                            if (mask and bit == 0L) continue
                            val r = try { provider.send(p.name, p.properties) } catch (_: Throwable) { ProviderResult.RETRY }
                            when (r) {
                                ProviderResult.SUCCESS -> successful.add(provider.providerId)
                                ProviderResult.RETRY   -> retrying.add(provider.providerId)
                                ProviderResult.DROP    -> dropped.add(provider.providerId)
                            }
                        }
                        q.ack(p.rowId, successful, retrying, dropped, p.pendingMask, p.retryCount)
                    }
                } catch (ie: InterruptedException) {
                    return@Thread
                } catch (e: Throwable) {
                    android.util.Log.w("UniTrack", "pending worker tick error: ${e.message}")
                }
            }
        }, "ut-pending-worker").apply { isDaemon = true }
        t.start()
        pendingWorker = t
    }

    private fun wakePendingWorker() { pendingWorker?.interrupt() }

    /** Snapshot count of events waiting to retry. For demo/debug UIs. */
    @JvmStatic
    fun pendingProviderRetryCount(): Int = pendingQueue?.count() ?: 0

    /**
     * Convenience: attach the built-in `FirebaseAdapter` that stamps UniTrack
     * `session_id` onto every Firebase Analytics event via reflection — 0
     * import of Firebase in UniTrack core. App can be missing Firebase: this
     * call is a no-op then. App can add Firebase tomorrow: this call starts
     * working immediately, no rebuild.
     *
     *   UniTrack.attachFirebaseAdapter(app)
     */
    @JvmStatic
    fun attachFirebaseAdapter(app: Application) {
        val adapter = com.unitrack.sdk.providers.FirebaseAdapter.create(app)
        if (adapter != null) addProvider(adapter)
    }

    /**
     * Register a built-in HttpProvider. Internal — call site is the remote
     * config reconciler (UniTrackRemoteConfig.applyHttpProviders). Portal is
     * the only source of truth for custom HTTP backends, so app code never
     * needs (and isn't allowed) to wire one by hand.
     */
    @JvmSynthetic
    internal fun addHttpProvider(
        id: String,
        endpoint: String,
        format: com.unitrack.sdk.providers.PayloadFormat = com.unitrack.sdk.providers.PayloadFormat.JSON_SINGLE,
        headers: Map<String, String> = emptyMap(),
        batchSize: Int = 50,
        flushIntervalMs: Long = 30_000,
    ) {
        addProvider(com.unitrack.sdk.providers.HttpProvider(
            id = id, endpoint = endpoint, format = format,
            headers = headers, batchSize = batchSize,
            flushIntervalMs = flushIntervalMs,
        ))
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
        // Cache wire-event names for the screen-boundary fan-out done in
        // setScreen() so providers receive screen_viewed / screen_exited
        // under whatever taxonomy the portal set — matching what the core
        // fires into the HTTP queue. journeyCapture=false disables both
        // arms (core skips lifecycle events; binding skips provider fan-out).
        screenStartEventName = config.screenStartEvent.ifEmpty { "screen_viewed" }
        screenEndEventName   = config.screenEndEvent.ifEmpty   { "screen_exited" }
        screenLifecycleEnabled = config.journeyCapture

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

        // Bring up the per-provider ack queue. Background worker polls every
        // 2s, drains events that pass next_retry_at, exponential backoff per
        // provider id (1s → 5min cap, max 10 retries, 7-day TTL).
        ensurePendingQueue(app)

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
                    dispatchToProviders("crash", props)
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
        // Cache cho customTrack(includeUser=true) stamp vào payload. App đã
        // hash PII trước khi gọi identify — SDK chỉ stamp, không tự hash.
        synchronized(identityLock) { identifiedUserId = userId }
        forEachProvider { it.setUser(userId, traits) }
        if (initialized) NativeBridge.identify(userId, JSONObject(traits).toString())
    }

    @JvmStatic
    fun reset() {
        synchronized(identityLock) { identifiedUserId = null }
        forEachProvider { it.setUser(null, emptyMap()) }
        if (initialized) NativeBridge.reset()
    }

    private val identityLock = Any()
    @Volatile private var identifiedUserId: String? = null

    /**
     * Custom event API — DEV gọi 1 dòng, SDK stamp `session_id` + `user_id`
     * (nếu includeUser) + forward qua provider fan-out + core HTTP queue.
     *
     * 2 pattern phổ biến:
     * 1. **1 schema = 1 action**: `customTrack("banner_clicked", data = ...)`
     * 2. **1 schema = nhiều action**: `customTrack("payment_event",
     *    action = "payment_completed", data = ...)`
     *
     * @param eventName tên event = Iglu schema name (snake_case).
     * @param action giá trị `event_action` field. null → SDK dùng eventName.
     * @param data map field tự do.
     * @param includeUser true → stamp `user_id` từ `UniTrack.identify()` đã set.
     */
    @JvmStatic
    @JvmOverloads
    fun customTrack(eventName: String,
                    action: String? = null,
                    data: Map<String, Any?> = emptyMap(),
                    includeUser: Boolean = false) {
        val payload = data.toMutableMap()
        payload["event_action"] = action ?: eventName
        payload["session_id"]   = currentSessionId()
        if (includeUser) {
            val uid = synchronized(identityLock) { identifiedUserId }
            if (!uid.isNullOrEmpty()) payload["user_id"] = uid
        }
        track(eventName, payload)
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

    /** Snapshot of events still sitting in the offline queue, grouped by raw
     *  event_name. Used by demo / debug UIs that show "Saved 3 ev_click,
     *  2 ev_result" while the device is offline. Empty map before init or
     *  when the queue is empty. */
    @JvmStatic
    fun pendingEventCounts(): Map<String, Int> {
        if (!initialized) return emptyMap()
        val json = NativeBridge.pendingEventCountsJson()
        return parseCountsJson(json)
    }

    /** Fires after each successful batch upload with the per-event_name
     *  breakdown of that batch (`{"ev_click": 3, "ev_result": 2}`). Apps
     *  use this to pop a toast during real-device offline testing.
     *
     *  Handler runs on the SDK worker thread — hop to Main before touching
     *  UI. Pass `null` to clear. */
    @JvmStatic
    fun onFlushCompleted(handler: ((Map<String, Int>) -> Unit)?) {
        if (!initialized) return
        if (handler == null) {
            NativeBridge.setFlushListener(null)
            return
        }
        NativeBridge.setFlushListener(NativeBridge.FlushListener { json ->
            handler(parseCountsJson(json))
        })
    }

    private fun parseCountsJson(json: String): Map<String, Int> {
        if (json.isBlank() || json == "{}") return emptyMap()
        return try {
            val obj = JSONObject(json)
            val out = LinkedHashMap<String, Int>(obj.length())
            val keys = obj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                out[k] = obj.optInt(k, 0)
            }
            out
        } catch (_: Throwable) {
            emptyMap()
        }
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
        dispatchToProviders(name, props)
        // Guard the native call: a tracking call can arrive before initialize()
        // finishes (e.g. RN's navigation tracker fires setScreen on first render
        // while initialize() is still in-flight). Calling JNI before
        // System.loadLibrary ran throws UnsatisfiedLinkError, so skip it.
        if (initialized) NativeBridge.track(name, JSONObject(props).toString())
    }

    @JvmStatic
    fun setScreen(name: String) = setScreen(name, reentry = false)

    /**
     * Vào lại đúng screen vừa rời — dùng cho resume sau background.
     *
     * onActivityStopped đã fire screen_exited cho screen này, nên khi app trở
     * lại foreground đây là boundary thật và phải fan-out screen_viewed.
     * Nhưng lastScreen vẫn giữ chính tên đó nên setScreen() thường sẽ bị dup
     * guard (isSameScreen) nuốt mất.
     *
     * Hàm này bypass guard đúng một lần và stamp previous = name: screen vào
     * lại từ chính nó. Provider nhận giá trị này thay vì tự suy — nếu để
     * Snowplow tự suy, previousName sẽ là màn đứng trước lúc background
     * (state nội bộ của nó không thấy exit), lệch với UniTrack.
     */
    internal fun reenterScreen(name: String) = setScreen(name, reentry = true)

    private fun setScreen(name: String, reentry: Boolean) {
        // Snapshot previous screen + transition timestamp on the binding side
        // so the boundary fan-out below can build matching screen_exited /
        // screen_viewed payloads for providers. The C++ core does its own
        // boundary work inside NativeBridge.setScreen — these two paths stay
        // in lockstep so the portal queue + Snowplow collector see identical
        // transitions (same field shape, same wire names from portal config).
        val now = System.currentTimeMillis()
        var previous: String?
        var dwellMs = 0L
        var isSameScreen = false
        var cameFrom: String? = null
        synchronized(screenLock) {
            previous = lastScreen
            // reentry (resume sau background): screen_exited đã fire lúc vào
            // bg nên đây là boundary thật dù tên trùng — bypass guard.
            isSameScreen = (previous == name) && !reentry
            // Tên screen thật sự vừa rời, lấy TRƯỚC khi guard reset previous
            // về null, để stamp xuống provider. Ở reentry nó chính là `name`.
            cameFrom = previous
            if (isSameScreen) previous = null
            val prev = previous
            if (prev != null && prev.isNotEmpty() && lastScreenAtMs > 0L) {
                dwellMs = now - lastScreenAtMs
            }
            lastScreen     = name
            lastScreenAtMs = now
        }
        // Gate provider setScreen bằng chính isSameScreen, và stamp previous
        // từ state của UniTrack — provider KHÔNG tự suy, nếu không hai nguồn
        // sự thật sẽ lệch (vd Snowplow builtin ScreenView ở resume ra
        // previousName = màn trước background).
        if (!isSameScreen) {
            forEachProvider { it.setScreen(name, cameFrom) }
        }
        if (initialized) NativeBridge.setScreen(name)

        // Fan-out boundary events to providers. Match the field names the
        // core emits (screen / screen_name / dwell_ms / foreground_sec /
        // from / from_screen / previous_screen_name / is_exit_screen) so
        // schema-aligned consumers see one canonical payload regardless of
        // which path delivered the event.
        // !reentry: onActivityStopped đã fire screen_exited cho screen này
        // rồi, fire lại ở đây là dup.
        if (screenLifecycleEnabled && !reentry) {
            val prev = previous
            if (prev != null && prev.isNotEmpty()) {
                // Per-screen counters — Snowplow builtin screen_summary/1-0-0
                // semantic. foreground_sec = tổng giây user active trên
                // screen vừa close. background_sec = tổng giây screen đó ở
                // bg. Roll về 0 ngay sau để screen mới đếm lại.
                val obs = com.unitrack.sdk.lifecycle.AppLifecycleObserver
                val fgSec = obs.foregroundDwellSec()
                val bgSec = obs.backgroundDwellSec()
                val endPayload: Map<String, Any?> = mapOf(
                    "screen"          to prev,
                    "screen_name"     to prev,
                    "dwell_ms"        to dwellMs.toString(),
                    "foreground_sec"  to fgSec.toString(),
                    "background_sec"  to bgSec.toString(),
                    // ponytail: string "false" thay vì Boolean để parity iOS
                    // + tránh Snowplow schema reject (boolean found, string expected).
                    "is_exit_screen"  to "false",
                )
                dispatchToProviders(screenEndEventName, endPayload)
                obs.rollScreenCounters()
            }
        }
        // screen start — dispatched with the app-configured raw name so
        // consumers pivoting on event_action / core_action.action_name see
        // the business name (screen_viewed) not the schema kind
        // (screen_view). Fire once regardless of screen_lifecycle.
        val startPayload = mutableMapOf<String, Any?>(
            "screen"      to name,
            "screen_name" to name,
        )
        val prev = previous
        if (screenLifecycleEnabled && prev != null && prev.isNotEmpty()) {
            startPayload["from"]                 = prev
            startPayload["from_screen"]          = prev
            startPayload["previous_screen_name"] = prev
        }
        // Dup guard (xem isSameScreen ở trên): swizzler re-fire onResume sau
        // khi pop dialog → cùng name, không có screen boundary → không
        // fan-out entry event nữa.
        if (!isSameScreen) {
            dispatchToProviders(screenStartEventName, startPayload)
        }
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
        // ponytail: string "true"/"false" — schema parity, tránh bad-event.
        p["is_cold"] = (elapsed in 0..coldDeeplinkWindowMs).toString()
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
     * auto-capture. Providers (FirebaseAdapter, SnowplowProvider) call this
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

    /**
     * Đoán xem process này có phải do user mở app không.
     *
     * initialize() chạy từ Application.onCreate(), tức TRƯỚC mọi Activity —
     * nhưng khi user chạm icon/noti, framework đã dựng sẵn ActivityThread's
     * activity record trước khi Application.onCreate() trả về. Khi process bị
     * FCM/JobService đánh thức thì không có record nào.
     *
     * Đọc qua reflection vì không có public API tương đương ở thời điểm này
     * (ActivityLifecycleCallbacks đăng ký sau initialize nên đã muộn). Bất kỳ
     * lỗi nào → trả về false = coi như user launch, tức giữ nguyên hành vi cũ.
     * Đoán sai theo hướng này chỉ mất đi phần tối ưu, không hỏng dữ liệu.
     */
    private fun detectHeadlessLaunch(): Boolean {
        return try {
            val atClass = Class.forName("android.app.ActivityThread")
            val thread = atClass.getMethod("currentActivityThread").invoke(null)
                ?: return false
            @Suppress("UNCHECKED_CAST")
            val activities = atClass.getDeclaredField("mActivities")
                .apply { isAccessible = true }
                .get(thread) as? Map<Any, Any>
                ?: return false
            activities.isEmpty()
        } catch (_: Throwable) {
            false
        }
    }

    private fun buildConfigJson(ctx: Context, c: UniTrackConfig): String {
        val obj = JSONObject()
        c.endpoint?.let { obj.put("endpoint", it) }
        obj.put("batch_size",        c.batchSize)
        obj.put("flush_interval_ms", c.flushIntervalMs)
        obj.put("sampling_rate",     c.samplingRate)
        obj.put("auto_capture",      c.autoCapture)
        obj.put("journey_capture",   c.journeyCapture)
        obj.put("session_timeout_ms", c.sessionTimeoutMs)
        headlessLaunch = c.headlessLaunch ?: detectHeadlessLaunch()
        obj.put("headless_launch",   headlessLaunch)
        obj.put("screen_lifecycle",   c.screenLifecycle)
        obj.put("screen_start_event", c.screenStartEvent)
        obj.put("screen_end_event",   c.screenEndEvent)
        obj.put("db_path",
                ctx.filesDir.absolutePath + "/unitrack_queue.db")
        return obj.toString()
    }

    internal const val PLATFORM_ANDROID = 2
}
