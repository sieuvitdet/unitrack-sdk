package com.unitrack.sdk.snowplow

import android.app.Application
import android.util.Log
import com.snowplowanalytics.snowplow.Snowplow
import com.snowplowanalytics.snowplow.configuration.NetworkConfiguration
import com.snowplowanalytics.snowplow.configuration.TrackerConfiguration
import com.snowplowanalytics.snowplow.controller.TrackerController
import com.snowplowanalytics.snowplow.event.ConsentGranted
import com.snowplowanalytics.snowplow.event.ConsentWithdrawn
import com.snowplowanalytics.snowplow.event.DeepLinkReceived
import com.snowplowanalytics.snowplow.event.EcommerceTransaction
import com.snowplowanalytics.snowplow.event.EcommerceTransactionItem
import com.snowplowanalytics.snowplow.event.MessageNotification
import com.snowplowanalytics.snowplow.event.MessageNotificationTrigger
import com.snowplowanalytics.snowplow.event.ScreenView
import com.snowplowanalytics.snowplow.event.SelfDescribing
import com.snowplowanalytics.snowplow.event.Structured
import com.snowplowanalytics.snowplow.event.Timing
import com.snowplowanalytics.snowplow.network.HttpMethod
import com.snowplowanalytics.snowplow.payload.SelfDescribingJson
import com.unitrack.sdk.providers.AnalyticsProvider

/**
 * Forwards every UniTrack event to a Snowplow collector.
 *
 *     UniTrack.addProvider(SnowplowProvider(
 *         endpoint = "https://collector.example.com",
 *         appId = "701",
 *         userContext = mapOf("username" to "duc"),
 *         userContextSchema = "iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0",
 *         schemas = mapOf("add_to_cart" to "iglu:com.acme/add_to_cart/jsonschema/1-0-0")))
 *
 * Events with a matching [schemas] entry → self-describing; others → Structured
 * (category "unitrack"). Optional user-context entity attached to every event.
 */
/**
 * Snowplow TrackerConfiguration flags the developer can toggle. Defaults match
 * Snowplow's recommended mobile setup; override any flag as needed.
 */
data class SnowplowOptions(
    val base64Encoding: Boolean = true,
    val platformContext: Boolean = true,
    val applicationContext: Boolean = true,
    val sessionContext: Boolean = true,
    val screenContext: Boolean = true,
    val lifecycleAutotracking: Boolean = true,
    val screenEngagementAutotracking: Boolean = true,
    val exceptionAutotracking: Boolean = true,
    val installAutotracking: Boolean = true,
    val userAnonymisation: Boolean = false,
)

class SnowplowProvider(
    private val endpoint: String,
    private val appId: String,
    private val namespace: String = "UniTrack",
    private var userContext: Map<String, Any?>? = null,
    private val userContextSchema: String? = null,
    private val schemas: Map<String, String> = emptyMap(),
    private val options: SnowplowOptions = SnowplowOptions(),
    /**
     * Convention vendor + version for the tracking* helpers. The schema URI
     * built per call is `iglu:<igluVendor>/<eventName>/jsonschema/<defaultVersion>`.
     * Both come from the portal; helpers warn + no-op when igluVendor is null.
     */
    private val igluVendor: String? = null,
    private val defaultVersion: String = "1-0-0",
    /**
     * Convention kind → event name override. Lets a third-party integrator
     * re-use the SDK helpers under their own taxonomy (e.g. "fss_event_click")
     * without forking. Helpers look up `eventNames[kind]` first, then fall
     * back to the SDK default name baked into the helper.
     */
    private var eventNames: Map<String, String> = emptyMap(),
) : AnalyticsProvider {

    /** Hot-reload the convention kind → event name map from a remote config push. */
    fun setEventNames(map: Map<String, String>) { this.eventNames = map }

    /** Resolve a convention kind ("click", "result", …) to an actual event name. */
    private fun eventName(kind: String, default: String): String =
        eventNames[kind]?.takeIf { it.isNotEmpty() } ?: default

    private var tracker: TrackerController? = null

    // Blueprint engine — mirrors the iOS/Flutter SnowplowProvider so an Android
    // app can resolve `track("camera_stream_started")` to a Snowplow self-
    // describing event via portal config, without hard-coding any schema URL
    // in app code.
    private var blueprints: Map<String, Map<String, Any?>> = emptyMap()
    private var entitiesById: Map<String, Map<String, Any?>> = emptyMap()
    private var eventBlueprintMap: Map<String, String> = emptyMap()
    private var globals: Map<String, Any?> = emptyMap()
    private var deviceBlob: Map<String, Any?> = emptyMap()

    override fun initialize(app: Application) {
        if (endpoint.isEmpty()) {
            Log.w("UniTrackSnowplow", "empty endpoint — provider disabled")
            return
        }
        val network = NetworkConfiguration(endpoint, HttpMethod.POST)
        // All flags come from the developer-supplied options.
        val trackerConfig = TrackerConfiguration(appId)
            .base64encoding(options.base64Encoding)
            .platformContext(options.platformContext)
            .applicationContext(options.applicationContext)
            .sessionContext(options.sessionContext)
            .screenContext(options.screenContext)
            .lifecycleAutotracking(options.lifecycleAutotracking)
            .screenEngagementAutotracking(options.screenEngagementAutotracking)
            .exceptionAutotracking(options.exceptionAutotracking)
            .installAutotracking(options.installAutotracking)
            .userAnonymisation(options.userAnonymisation)
        tracker = Snowplow.createTracker(app, namespace, network, trackerConfig)
        com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
            "tracker ready ($endpoint, appId=$appId, lifecycle=${options.lifecycleAutotracking})")
    }

    fun updateUserContext(ctx: Map<String, Any?>) { userContext = ctx }

    /**
     * Install blueprint + entity catalog from the portal (already deserialized
     * to Kotlin maps). After this, calls to [track] check the eventBlueprintMap
     * first; if there's a hit, the event becomes a SelfDescribing with
     * attach_entities resolved from props/globals/device.
     */
    fun applyBlueprintConfig(blueprints: Map<String, Map<String, Any?>>,
                             entities:   Map<String, Map<String, Any?>>,
                             eventBlueprintMap: Map<String, String>) {
        this.blueprints = blueprints
        this.entitiesById = entities
        this.eventBlueprintMap = eventBlueprintMap
        com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
            "blueprint config: blueprints=${blueprints.size}, entities=${entities.size}, mapped=${eventBlueprintMap.size}")
    }

    /** Device blob — populated once at start (platform, app_bundle/version, model). */
    fun setDeviceBlob(blob: Map<String, Any?>) { deviceBlob = blob }

    /** Global context bag — session_id, user, flavor, … */
    fun setGlobalContext(ctx: Map<String, Any?>) { globals = ctx }

    private fun entities(): List<SelfDescribingJson> {
        val ctx = userContext ?: return emptyList()
        val schema = userContextSchema ?: return emptyList()
        return listOf(SelfDescribingJson(schema, ctx.mapValues { it.value ?: "" }))
    }

    // Exact match wins; then any `prefix_*` entry whose prefix matches.
    private fun resolveBlueprintId(eventName: String): String? {
        eventBlueprintMap[eventName]?.let { return it }
        for ((k, v) in eventBlueprintMap) {
            if (k.endsWith("*")) {
                val prefix = k.dropLast(1)
                if (eventName.startsWith(prefix)) return v
            }
        }
        return null
    }

    // Build a (schema, data) tuple for the named entity by reading the entity's
    // field map { name: { from: globals|device|props|event_name|literal, key/value } }.
    // Pretty logging needs the raw data map (SelfDescribingJson on the Android
    // Snowplow tracker doesn't expose it post-construction), so we return the
    // pair and let the caller construct SelfDescribingJson + log from one source.
    data class EntityPayload(val schema: String, val data: Map<String, Any?>) {
        fun toSdj(): SelfDescribingJson =
            SelfDescribingJson(schema, data.mapValues { it.value ?: "" })
    }

    private fun buildEntity(entityId: String,
                            props: Map<String, Any?>,
                            eventName: String): EntityPayload? {
        val entity = entitiesById[entityId] ?: return null
        val schema = entity["schema"] as? String ?: return null
        @Suppress("UNCHECKED_CAST")
        val fields = entity["fields"] as? Map<String, Map<String, Any?>> ?: return null
        val data = mutableMapOf<String, Any?>()
        for ((fieldName, spec) in fields) {
            val from = (spec["from"] as? String) ?: "props"
            when (from) {
                "props" -> {
                    val key = (spec["key"] as? String) ?: fieldName
                    if (props.containsKey(key)) data[fieldName] = props[key]
                    else spec["default"]?.let { data[fieldName] = it }
                }
                "globals" -> {
                    val path = (spec["key"] as? String) ?: ""
                    if (path.isNotEmpty()) {
                        val v = lookupDotted(globals, path)
                        if (v != null) data[fieldName] = v
                        else spec["default"]?.let { data[fieldName] = it }
                    }
                }
                "device" -> {
                    val key = (spec["key"] as? String) ?: fieldName
                    if (deviceBlob.containsKey(key)) data[fieldName] = deviceBlob[key]
                    else spec["default"]?.let { data[fieldName] = it }
                }
                "event_name" -> data[fieldName] = eventName
                "literal"    -> spec["value"]?.let { data[fieldName] = it }
                else         -> spec["default"]?.let { data[fieldName] = it }
            }
            // "default: now" → ISO-8601 timestamp for any field still unresolved.
            if (data[fieldName] == null && (spec["default"] as? String) == "now") {
                data[fieldName] = java.time.Instant.now().toString()
            }
        }
        return if (data.isEmpty()) null else EntityPayload(schema, data)
    }

    @Suppress("UNCHECKED_CAST")
    private fun lookupDotted(root: Map<String, Any?>, path: String): Any? {
        var cur: Any? = root
        for (part in path.split('.')) {
            cur = (cur as? Map<String, Any?>)?.get(part) ?: return null
        }
        return cur
    }

    // Strip helper markers (_skip_snowplow, _sp_*, _schema) + nil values.
    private fun cleanedEventData(props: Map<String, Any?>): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        for ((k, v) in props) {
            if (k.startsWith("_")) continue
            out[k] = v
        }
        return out
    }

    override fun track(name: String, properties: Map<String, Any?>) {
        val t = tracker
        if (t == null) {
            com.unitrack.sdk.UniTrack.log("UniTrackSnowplow", "SKIP \"$name\" — tracker not initialized")
            return
        }
        // App fired this event into Snowplow already through a legacy path —
        // mirror to portal only, drop the Snowplow leg here.
        if (properties["_skip_snowplow"] == true) {
            com.unitrack.sdk.UniTrack.log("UniTrackSnowplow", "SKIP \"$name\" — _skip_snowplow=true")
            return
        }

        // Resolution order (richest first → simplest):
        //   1. Blueprint match → SelfDescribing with attach_entities resolved
        //   2. schemas[name] map → SelfDescribing + global user_context only
        //   3. Structured event (category/action/label/property)
        val blueprintId = resolveBlueprintId(name)
        val blueprint = blueprintId?.let { blueprints[it] }
        val bpSchema = blueprint?.get("schema") as? String
        if (bpSchema != null) {
            @Suppress("UNCHECKED_CAST")
            val attach = (blueprint["attach_entities"] as? List<String>) ?: emptyList()
            val builtCtx = mutableListOf<EntityPayload>()
            for (entId in attach) {
                buildEntity(entId, properties, name)?.let { builtCtx.add(it) }
            }
            // user_context fallback — same rule as iOS: only if blueprint
            // doesn't already list it.
            val userCtxPayload: EntityPayload? =
                if (!attach.contains("user_context") && userContext != null && userContextSchema != null)
                    EntityPayload(userContextSchema, userContext!!) else null
            userCtxPayload?.let { builtCtx.add(it) }
            val data = cleanedEventData(properties)
            val event = SelfDescribing(SelfDescribingJson(bpSchema, data.mapValues { it.value ?: "" }))
            event.entities.addAll(builtCtx.map { it.toSdj() })
            t.track(event)
            logTracking("trackSelfDescribingEvent", bpSchema, data, builtCtx,
                        extra = "blueprint=\"$blueprintId\" event=\"$name\"")
            return
        }

        val schema = schemas[name]
        if (schema != null) {
            val data = cleanedEventData(properties)
            val event = SelfDescribing(SelfDescribingJson(schema, data.mapValues { it.value ?: "" }))
            val userPayload: EntityPayload? =
                if (userContext != null && userContextSchema != null)
                    EntityPayload(userContextSchema, userContext!!) else null
            userPayload?.let { event.entities.add(it.toSdj()) }
            t.track(event)
            logTracking("trackSelfDescribingEvent", schema, data,
                        if (userPayload != null) listOf(userPayload) else emptyList(),
                        extra = "schemas[name] event=\"$name\"")
            return
        }

        val structured = Structured("unitrack", name).apply {
            label = (properties["screen"] ?: properties["screen_name"])?.toString()
            property = (properties["element_key"] ?: properties["state"])?.toString()
        }
        val ctxs = entities()
        structured.entities.addAll(ctxs)
        t.track(structured)
        com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
            "SEND structured event=\"$name\" label=${structured.label ?: "—"} property=${structured.property ?: "—"}")
    }

    override fun setUser(userId: String?, traits: Map<String, Any?>) {
        tracker?.subject?.userId = userId
        if (traits.isNotEmpty() && userContext != null) {
            userContext = userContext!! + traits
        }
    }

    override fun setScreen(name: String) {
        val t = tracker ?: return
        val sv = ScreenView(name)
        sv.entities.addAll(entities())
        t.track(sv)
    }

    // ─── First-class helpers for Snowplow built-in events ──────────────────
    //
    // Mirrors the iOS provider's helpers 1-1. The plain track() above falls
    // back to either Structured or (via blueprint / schemas map) SelfDescribing;
    // these are for the 5 typed events the Snowplow tracker SDK already models,
    // so app code doesn't pass strings + match iglu schemas by hand.
    //
    // `extraContexts` lets the caller attach event-scoped contexts (campaign,
    // experiment, screen, …). When `skipGlobalContexts` is true the global
    // user_context is dropped — useful when the caller is overriding it with
    // an event-scoped one (e.g. a logout event clearing the user).

    /** Build the entity list for one event: global user_context (unless suppressed) + extras. */
    private fun buildEntities(extra: List<SelfDescribingJson>?,
                              skipGlobalContexts: Boolean): List<SelfDescribingJson> {
        val list = mutableListOf<SelfDescribingJson>()
        if (!skipGlobalContexts) list.addAll(entities())
        if (extra != null) list.addAll(extra)
        return list
    }

    /** Timing event — duration measurements (API latency, animation, …). */
    fun trackTiming(category: String,
                    variable: String,
                    timing: Int,
                    label: String? = null,
                    extraContexts: List<SelfDescribingJson>? = null,
                    skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = Timing(category, variable, timing)
        if (label != null) ev.label = label
        ev.entities.addAll(buildEntities(extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    /**
     * Legacy ecommerce transaction. Snowplow v6 deprecated this class in favour
     * of the richer Ecommerce package (productView, addToCart, checkout, …),
     * but the one-shot transaction shape is still emitted to the collector and
     * remains the simplest API for "order placed" tracking. Switch the helper
     * over to the new package when an app actually needs the finer steps.
     */
    @Suppress("DEPRECATION")
    fun trackEcommerceTransaction(orderId: String,
                                  totalValue: Double,
                                  items: List<EcommerceTransactionItem>,
                                  affiliation: String? = null,
                                  taxValue: Double? = null,
                                  shipping: Double? = null,
                                  city: String? = null,
                                  state: String? = null,
                                  country: String? = null,
                                  currency: String? = null,
                                  extraContexts: List<SelfDescribingJson>? = null,
                                  skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = EcommerceTransaction(orderId, totalValue, items)
        if (affiliation != null) ev.affiliation = affiliation
        if (taxValue    != null) ev.taxValue    = taxValue
        if (shipping    != null) ev.shipping    = shipping
        if (city        != null) ev.city        = city
        if (state       != null) ev.state       = state
        if (country     != null) ev.country     = country
        if (currency    != null) ev.currency    = currency
        ev.entities.addAll(buildEntities(extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    /** MessageNotification — push received / opened. trigger defaults to PUSH. */
    fun trackMessageNotification(title: String,
                                 body: String,
                                 trigger: MessageNotificationTrigger = MessageNotificationTrigger.push,
                                 notificationTimestamp: String? = null,
                                 category: String? = null,
                                 action: String? = null,
                                 sound: String? = null,
                                 extraContexts: List<SelfDescribingJson>? = null,
                                 skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = MessageNotification(title, body, trigger)
        if (notificationTimestamp != null) ev.notificationTimestamp = notificationTimestamp
        if (category != null) ev.category = category
        if (action   != null) ev.action   = action
        if (sound    != null) ev.sound    = sound
        ev.entities.addAll(buildEntities(extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    /** DeepLinkReceived — OS handed the app a URL (custom scheme / app link). */
    fun trackDeepLink(url: String,
                      referrer: String? = null,
                      extraContexts: List<SelfDescribingJson>? = null,
                      skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = DeepLinkReceived(url)
        if (referrer != null) ev.referrer = referrer
        ev.entities.addAll(buildEntities(extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    /** ConsentGranted — user accepts a privacy/consent document. expiry is ISO-8601. */
    fun trackConsentGranted(expiry: String,
                            documentId: String,
                            documentVersion: String,
                            documentName: String? = null,
                            documentDescription: String? = null,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = ConsentGranted(expiry, documentId, documentVersion)
        if (documentName != null)        ev.documentName = documentName
        if (documentDescription != null) ev.documentDescription = documentDescription
        ev.entities.addAll(buildEntities(extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    /**
     * ConsentWithdrawn — user revokes a consent. Pass all=true to revoke every
     * grant in one call (documentId / version may be empty strings — Snowplow's
     * iglu doc ignores them when all=true).
     */
    fun trackConsentWithdrawn(all: Boolean,
                              documentId: String = "",
                              documentVersion: String = "",
                              documentName: String? = null,
                              documentDescription: String? = null,
                              extraContexts: List<SelfDescribingJson>? = null,
                              skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = ConsentWithdrawn(all, documentId, documentVersion)
        if (documentName != null)        ev.documentName = documentName
        if (documentDescription != null) ev.documentDescription = documentDescription
        ev.entities.addAll(buildEntities(extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    /**
     * Self-describing event with custom contexts. The 1-1 match for the JSON
     * shape Snowplow's tp2 collector receives:
     *   { event: { schema, data }, contexts: [ {schema,data}, … ] }
     * `extraContexts` is added AFTER the global user_context unless
     * `skipGlobalContexts: true` — same rule as the typed helpers above.
     */
    fun trackSelfDescribing(schema: String,
                            data: Map<String, Any?>,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = SelfDescribing(SelfDescribingJson(schema, data.mapValues { it.value ?: "" }))
        ev.entities.addAll(buildEntities(extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    // ─── Convention layer ──────────────────────────────────────────────────
    //
    // The 6 tracking* helpers below are what app code calls day-to-day. Each
    // hardcodes a convention event name ("event_click", "event_screen_view",
    // …); the iglu schema URI is built at call site from the portal config:
    //
    //     iglu:<igluVendor>/<event_name>/jsonschema/<defaultVersion>
    //
    // Bumping a schema major across the whole app = updating defaultVersion
    // on the portal; no app rebuild. trackingCustomEvent is the escape hatch
    // for any event the team hasn't lifted into a typed helper yet.
    // Parity 1-1 with the iOS SnowplowProvider.

    /** Build the convention schema URI. Returns null + warns when no vendor. */
    private fun schemaFor(eventName: String): String? {
        val vendor = igluVendor
        if (vendor.isNullOrEmpty()) {
            com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
                "no iglu_vendor in portal config — \"$eventName\" dropped. Set snowplow.iglu_vendor in the portal Config tab.")
            return null
        }
        return "iglu:$vendor/$eventName/jsonschema/$defaultVersion"
    }

    /** Convention event for a button tap. Schema: `<vendor>/event_click`. */
    fun trackingClickEvent(elementKey: String,
                           label: String? = null,
                           screen: String? = null,
                           data: Map<String, Any?>? = null,
                           extraContexts: List<SelfDescribingJson>? = null,
                           skipGlobalContexts: Boolean = false) {
        val schema = schemaFor(eventName("click", "event_click")) ?: return
        val payload = mutableMapOf<String, Any?>("element_key" to elementKey)
        if (label  != null) payload["label"]  = label
        if (screen != null) payload["screen"] = screen
        if (data   != null) payload.putAll(data)
        trackSelfDescribing(schema, payload, extraContexts, skipGlobalContexts)
    }

    /** Convention event for the outcome of an action. Schema: `<vendor>/event_result`. */
    fun trackingResultEvent(action: String,
                            status: String,
                            errorCode: String? = null,
                            errorMessage: String? = null,
                            durationMs: Int? = null,
                            data: Map<String, Any?>? = null,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val schema = schemaFor(eventName("result", "event_result")) ?: return
        val payload = mutableMapOf<String, Any?>("action" to action, "status" to status)
        if (errorCode    != null) payload["error_code"]    = errorCode
        if (errorMessage != null) payload["error_message"] = errorMessage
        if (durationMs   != null) payload["duration_ms"]   = durationMs
        if (data         != null) payload.putAll(data)
        trackSelfDescribing(schema, payload, extraContexts, skipGlobalContexts)
    }

    /**
     * Convention event for entering a screen. Emits BOTH the Snowplow native
     * ScreenView (sessionization, screen context) AND a SelfDescribing
     * `event_screen_view` against the team vendor — one call, two payloads.
     */
    fun trackingScreenView(screenName: String,
                           fromScreen: String? = null,
                           data: Map<String, Any?>? = null,
                           extraContexts: List<SelfDescribingJson>? = null,
                           skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val sv = ScreenView(screenName)
        sv.entities.addAll(buildEntities(null, skipGlobalContexts))
        t.track(sv)
        val schema = schemaFor(eventName("screen_view", "event_screen_view")) ?: return
        val payload = mutableMapOf<String, Any?>("screen_name" to screenName)
        if (fromScreen != null) payload["from_screen"] = fromScreen
        if (data       != null) payload.putAll(data)
        trackSelfDescribing(schema, payload, extraContexts, skipGlobalContexts)
    }

    /** Convention event for a crash report. Schema: `<vendor>/event_crash`. */
    fun trackingCrash(message: String,
                      stack: String? = null,
                      fatal: Boolean = true,
                      type: String? = null,
                      data: Map<String, Any?>? = null,
                      extraContexts: List<SelfDescribingJson>? = null,
                      skipGlobalContexts: Boolean = false) {
        val schema = schemaFor(eventName("crash", "event_crash")) ?: return
        val payload = mutableMapOf<String, Any?>("message" to message, "fatal" to fatal)
        if (stack != null) payload["stack"] = stack
        if (type  != null) payload["type"]  = type
        if (data  != null) payload.putAll(data)
        trackSelfDescribing(schema, payload, extraContexts, skipGlobalContexts)
    }

    /**
     * Convention event for an HTTP observation. Schema: `<vendor>/event_api`.
     * Use this when wrapping a transport UniTrack core can't see (gRPC,
     * websocket, custom). OkHttp/URLConnection traffic is auto-captured.
     */
    fun trackingAPI(url: String,
                    method: String,
                    status: Int,
                    durationMs: Int,
                    requestBytes: Int? = null,
                    responseBytes: Int? = null,
                    errorMessage: String? = null,
                    data: Map<String, Any?>? = null,
                    extraContexts: List<SelfDescribingJson>? = null,
                    skipGlobalContexts: Boolean = false) {
        val schema = schemaFor(eventName("api", "event_api")) ?: return
        val payload = mutableMapOf<String, Any?>(
            "url" to url, "method" to method, "status" to status, "duration_ms" to durationMs)
        if (requestBytes  != null) payload["request_bytes"]  = requestBytes
        if (responseBytes != null) payload["response_bytes"] = responseBytes
        if (errorMessage  != null) payload["error_message"]  = errorMessage
        if (data          != null) payload.putAll(data)
        trackSelfDescribing(schema, payload, extraContexts, skipGlobalContexts)
    }

    /** Escape hatch for any convention name not (yet) lifted into a typed helper. */
    fun trackingCustomEvent(eventName: String,
                            data: Map<String, Any?>? = null,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val schema = schemaFor(eventName) ?: return
        trackSelfDescribing(schema, data ?: emptyMap(), extraContexts, skipGlobalContexts)
    }

    // Pretty-print envelope mirroring iOS — {endpoint, method, event:{schema,data}, contexts:[{schema,data},…]}
    private fun logTracking(method: String, eventSchema: String,
                            eventData: Map<String, Any?>,
                            contexts: List<EntityPayload>,
                            extra: String) {
        if (!com.unitrack.sdk.UniTrack.verboseLogging) return
        val ctxsArr = org.json.JSONArray()
        for (c in contexts) {
            ctxsArr.put(org.json.JSONObject()
                .put("schema", c.schema)
                .put("data", org.json.JSONObject(c.data.mapValues { it.value ?: org.json.JSONObject.NULL })))
        }
        val envelope = org.json.JSONObject()
            .put("endpoint", endpoint)
            .put("method", method)
            .put("event", org.json.JSONObject()
                .put("schema", eventSchema)
                .put("data", org.json.JSONObject(eventData.mapValues { it.value ?: org.json.JSONObject.NULL })))
            .put("contexts", ctxsArr)
        com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
            "\n─── Snowplow Tracking ───  ($extra)\n${envelope.toString(2)}")
    }
}
