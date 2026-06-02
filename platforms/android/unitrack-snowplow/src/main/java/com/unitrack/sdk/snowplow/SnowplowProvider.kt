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
import com.snowplowanalytics.snowplow.event.Timing
import com.snowplowanalytics.snowplow.network.HttpMethod
import com.snowplowanalytics.snowplow.payload.SelfDescribingJson
import com.unitrack.sdk.providers.AnalyticsProvider

/**
 * SnowplowProvider — forwards UniTrack events to a Snowplow collector via the
 * "convention layer". App code calls one of the 6 tracking* helpers below;
 * the SDK builds the iglu schema URI per call from portal config:
 *
 *   iglu:<igluVendor>/<eventName>/jsonschema/<defaultVersion>
 *
 * where eventName comes from `eventNames[kind]` (portal `event_names.<kind>`)
 * or falls back to the SDK default name baked into the helper. Two context
 * entities are auto-attached to every call:
 *
 *   user_context — data sourced from setUser(...) + the userContext bag.
 *   core_action  — action_name (the resolved event name), timestamp (now),
 *                  screen, element_key.
 *
 * Both entity schema URIs come from portal `entities.<name>`. Adding extra
 * entity names to that map registers them, but the app must supply their
 * data per-call via the helper's `extraContexts` parameter — the SDK only
 * builds user_context + core_action from app state on its own.
 *
 * The Structured + per-event-name `schemas[]` lookup paths from the previous
 * "blueprint engine" iteration are gone; `track(name, props)` is the lone
 * generic call left, and it now goes out as a self-describing event under
 * the convention schema (eventName = `name` passed in).
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
    private var userContext: MutableMap<String, Any?> = mutableMapOf(),
    private val options: SnowplowOptions = SnowplowOptions(),
    /** Convention vendor — schema URI is iglu:<igluVendor>/<name>/jsonschema/<defaultVersion>. */
    private val igluVendor: String? = null,
    private val defaultVersion: String = "1-0-0",
    /** Convention kind → event name override. Portal `event_names.<kind>`. */
    private var eventNames: Map<String, String> = emptyMap(),
    /** Auto-attached context entity name → schema URI. */
    private var entities: Map<String, String> = emptyMap(),
) : AnalyticsProvider {

    private var tracker: TrackerController? = null

    override fun initialize(app: Application) {
        if (endpoint.isEmpty()) {
            Log.w("UniTrackSnowplow", "empty endpoint — provider disabled")
            return
        }
        val network = NetworkConfiguration(endpoint, HttpMethod.POST)
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
            "tracker ready ($endpoint, appId=$appId, vendor=${igluVendor ?: "—"}, version=$defaultVersion, entities=${entities.keys.sorted().joinToString(",")})")
    }

    // ── Hot reloads from remote config ───────────────────────────────────

    fun updateUserContext(ctx: Map<String, Any?>) {
        userContext = ctx.toMutableMap()
    }
    fun setEventNames(map: Map<String, String>) { eventNames = map }
    fun setEntities(map: Map<String, String>)   { entities = map }

    // ── AnalyticsProvider protocol ───────────────────────────────────────

    override fun setUser(userId: String?, traits: Map<String, Any?>) {
        tracker?.subject?.userId = userId
        if (userId != null) userContext["user_id"] = userId
        for ((k, v) in traits) userContext[k] = v
    }

    override fun track(name: String, properties: Map<String, Any?>) {
        if (properties["_skip_snowplow"] == true) {
            com.unitrack.sdk.UniTrack.log("UniTrackSnowplow", "SKIP \"$name\" — _skip_snowplow=true")
            return
        }
        val schema = schemaFor(name) ?: return
        trackSelfDescribingInternal(schema, name, properties, null, false)
    }

    override fun setScreen(name: String) {
        val t = tracker ?: return
        val sv = ScreenView(name)
        sv.entities.addAll(buildEntities(name, screen = name, elementKey = null,
                                         extra = null, skipGlobalContexts = false))
        t.track(sv)
    }

    // ── Convention schema/entity plumbing ────────────────────────────────

    private fun schemaFor(eventName: String): String? {
        val vendor = igluVendor
        if (vendor.isNullOrEmpty()) {
            com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
                "no iglu_vendor in portal config — \"$eventName\" dropped. Set snowplow.iglu_vendor in the portal Config tab.")
            return null
        }
        return "iglu:$vendor/$eventName/jsonschema/$defaultVersion"
    }

    /**
     * Accept any of these inputs from portal entity config and return a
     * well-formed iglu URI. Defensive — UI guides operator to enter a short
     * name, but old configs may carry a full URI and a typo can drop the
     * "iglu:" scheme; we fix both here.
     *
     *   "user_context"                                            → iglu:<vendor>/user_context/jsonschema/<defaultVersion>
     *   "vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0"      → iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0
     *   "iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0" → unchanged
     */
    private fun normalizeEntityURI(raw: String): String? {
        val s = raw.trim()
        if (s.isEmpty()) return null
        if (s.startsWith("iglu:")) return s
        if (s.contains("/")) return "iglu:$s"
        val vendor = igluVendor
        if (vendor.isNullOrEmpty()) return null
        return "iglu:$vendor/$s/jsonschema/$defaultVersion"
    }

    private fun eventName(kind: String, default: String): String =
        eventNames[kind]?.takeIf { it.isNotEmpty() } ?: default

    /**
     * Build the entity list attached to one event:
     *   1. user_context — from userContext bag (if entities["user_context"] set)
     *   2. core_action  — from event meta (if entities["core_action"] set)
     *   3. extra        — anything the caller passed
     * Any other entity name registered in `entities` is registered but data-less;
     * pass it via `extraContexts` when calling the helper.
     */
    private fun buildEntities(eventName: String,
                              screen: String?,
                              elementKey: String?,
                              extra: List<SelfDescribingJson>?,
                              skipGlobalContexts: Boolean): List<SelfDescribingJson> {
        val out = mutableListOf<SelfDescribingJson>()
        if (!skipGlobalContexts) {
            val userSchema = entities["user_context"]?.let { normalizeEntityURI(it) }
            if (userSchema != null && userContext.isNotEmpty()) {
                out.add(SelfDescribingJson(userSchema,
                    userContext.mapValues { it.value ?: "" }))
            }
            val coreSchema = entities["core_action"]?.let { normalizeEntityURI(it) }
            if (coreSchema != null) {
                val data = mutableMapOf<String, Any?>(
                    "action_name" to eventName,
                    "timestamp"   to java.time.Instant.now().toString(),
                )
                if (!screen.isNullOrEmpty())     data["screen"]      = screen
                if (!elementKey.isNullOrEmpty()) data["element_key"] = elementKey
                out.add(SelfDescribingJson(coreSchema, data.mapValues { it.value ?: "" }))
            }
        }
        if (extra != null) out.addAll(extra)
        return out
    }

    private fun cleanedData(props: Map<String, Any?>): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        for ((k, v) in props) {
            if (k.startsWith("_")) continue
            out[k] = v
        }
        return out
    }

    private fun trackSelfDescribingInternal(schema: String,
                                            eventName: String,
                                            data: Map<String, Any?>,
                                            extra: List<SelfDescribingJson>?,
                                            skipGlobalContexts: Boolean) {
        val t = tracker ?: run {
            com.unitrack.sdk.UniTrack.log("UniTrackSnowplow", "SKIP \"$eventName\" — tracker not initialized")
            return
        }
        val cleaned = cleanedData(data)
        val screen     = (cleaned["screen"]      ?: cleaned["screen_name"]) as? String
        val elementKey = (cleaned["element_key"] ?: cleaned["element"])     as? String
        val ctxs = buildEntities(eventName, screen, elementKey, extra, skipGlobalContexts)
        val ev = SelfDescribing(SelfDescribingJson(schema, cleaned.mapValues { it.value ?: "" }))
        ev.entities.addAll(ctxs)
        t.track(ev)
        logTracking(schema, eventName, cleaned, ctxs)
    }

    // ── Snowplow built-in event helpers ──────────────────────────────────

    fun trackTiming(category: String, variable: String, timing: Int,
                    label: String? = null,
                    extraContexts: List<SelfDescribingJson>? = null,
                    skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = Timing(category, variable, timing)
        if (label != null) ev.label = label
        ev.entities.addAll(buildEntities("timing", null, null, extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    @Suppress("DEPRECATION")
    fun trackEcommerceTransaction(orderId: String, totalValue: Double,
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
        ev.entities.addAll(buildEntities("ecommerce_transaction", null, null,
                                         extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    fun trackMessageNotification(title: String, body: String,
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
        ev.entities.addAll(buildEntities("message_notification", null, null,
                                         extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    fun trackDeepLink(url: String, referrer: String? = null,
                      extraContexts: List<SelfDescribingJson>? = null,
                      skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = DeepLinkReceived(url)
        if (referrer != null) ev.referrer = referrer
        ev.entities.addAll(buildEntities("deep_link_received", null, null,
                                         extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    fun trackConsentGranted(expiry: String, documentId: String, documentVersion: String,
                            documentName: String? = null,
                            documentDescription: String? = null,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val ev = ConsentGranted(expiry, documentId, documentVersion)
        if (documentName != null)        ev.documentName = documentName
        if (documentDescription != null) ev.documentDescription = documentDescription
        ev.entities.addAll(buildEntities("consent_granted", null, null,
                                         extraContexts, skipGlobalContexts))
        t.track(ev)
    }

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
        ev.entities.addAll(buildEntities("consent_withdrawn", null, null,
                                         extraContexts, skipGlobalContexts))
        t.track(ev)
    }

    /**
     * Self-describing event with caller-provided schema. Skips the convention
     * schema builder; auto-entities still attach unless skipGlobalContexts.
     */
    fun trackSelfDescribing(schema: String, data: Map<String, Any?>,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val nameHint = (data["action_name"] ?: data["event_name"]) as? String ?: "self_describing"
        trackSelfDescribingInternal(schema, nameHint, data, extraContexts, skipGlobalContexts)
    }

    // ── Convention helpers (app-facing) ──────────────────────────────────

    fun trackingClickEvent(elementKey: String,
                           label: String? = null,
                           screen: String? = null,
                           data: Map<String, Any?>? = null,
                           extraContexts: List<SelfDescribingJson>? = null,
                           skipGlobalContexts: Boolean = false) {
        val name = eventName("click", "event_click")
        val schema = schemaFor(name) ?: return
        val payload = mutableMapOf<String, Any?>("element_key" to elementKey)
        if (label  != null) payload["label"]  = label
        if (screen != null) payload["screen"] = screen
        if (data   != null) payload.putAll(data)
        trackSelfDescribingInternal(schema, name, payload, extraContexts, skipGlobalContexts)
    }

    fun trackingResultEvent(action: String, status: String,
                            errorCode: String? = null, errorMessage: String? = null,
                            durationMs: Int? = null, data: Map<String, Any?>? = null,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val name = eventName("result", "event_result")
        val schema = schemaFor(name) ?: return
        val payload = mutableMapOf<String, Any?>("action" to action, "status" to status)
        if (errorCode    != null) payload["error_code"]    = errorCode
        if (errorMessage != null) payload["error_message"] = errorMessage
        if (durationMs   != null) payload["duration_ms"]   = durationMs
        if (data         != null) payload.putAll(data)
        trackSelfDescribingInternal(schema, name, payload, extraContexts, skipGlobalContexts)
    }

    /**
     * Convention event for entering a screen. Emits BOTH the Snowplow native
     * ScreenView (sessionization, screen context) AND a SelfDescribing event
     * against the team vendor — one call, two payloads.
     */
    fun trackingScreenView(screenName: String, fromScreen: String? = null,
                           data: Map<String, Any?>? = null,
                           extraContexts: List<SelfDescribingJson>? = null,
                           skipGlobalContexts: Boolean = false) {
        val t = tracker ?: return
        val sv = ScreenView(screenName)
        sv.entities.addAll(buildEntities("screen_view", screenName, null, null, skipGlobalContexts))
        t.track(sv)
        val name = eventName("screen_view", "event_screen_view")
        val schema = schemaFor(name) ?: return
        val payload = mutableMapOf<String, Any?>("screen_name" to screenName, "screen" to screenName)
        if (fromScreen != null) payload["from_screen"] = fromScreen
        if (data       != null) payload.putAll(data)
        trackSelfDescribingInternal(schema, name, payload, extraContexts, skipGlobalContexts)
    }

    fun trackingCrash(message: String, stack: String? = null,
                      fatal: Boolean = true, type: String? = null,
                      data: Map<String, Any?>? = null,
                      extraContexts: List<SelfDescribingJson>? = null,
                      skipGlobalContexts: Boolean = false) {
        val name = eventName("crash", "event_crash")
        val schema = schemaFor(name) ?: return
        val payload = mutableMapOf<String, Any?>("message" to message, "fatal" to fatal)
        if (stack != null) payload["stack"] = stack
        if (type  != null) payload["type"]  = type
        if (data  != null) payload.putAll(data)
        trackSelfDescribingInternal(schema, name, payload, extraContexts, skipGlobalContexts)
    }

    fun trackingAPI(url: String, method: String, status: Int, durationMs: Int,
                    requestBytes: Int? = null, responseBytes: Int? = null,
                    errorMessage: String? = null, data: Map<String, Any?>? = null,
                    extraContexts: List<SelfDescribingJson>? = null,
                    skipGlobalContexts: Boolean = false) {
        val name = eventName("api", "event_api")
        val schema = schemaFor(name) ?: return
        val payload = mutableMapOf<String, Any?>(
            "url" to url, "method" to method, "status" to status, "duration_ms" to durationMs)
        if (requestBytes  != null) payload["request_bytes"]  = requestBytes
        if (responseBytes != null) payload["response_bytes"] = responseBytes
        if (errorMessage  != null) payload["error_message"]  = errorMessage
        if (data          != null) payload.putAll(data)
        trackSelfDescribingInternal(schema, name, payload, extraContexts, skipGlobalContexts)
    }

    fun trackingCustomEvent(eventName: String,
                            data: Map<String, Any?>? = null,
                            extraContexts: List<SelfDescribingJson>? = null,
                            skipGlobalContexts: Boolean = false) {
        val schema = schemaFor(eventName) ?: return
        trackSelfDescribingInternal(schema, eventName, data ?: emptyMap(),
                                    extraContexts, skipGlobalContexts)
    }

    // ── Pretty log envelope (verbose only) ───────────────────────────────

    private fun logTracking(schema: String, eventName: String,
                            data: Map<String, Any?>, contexts: List<SelfDescribingJson>) {
        if (!com.unitrack.sdk.UniTrack.verboseLogging) return
        val ctxsArr = org.json.JSONArray()
        for (c in contexts) {
            // Snowplow v6 hides the schema field but exposes the whole payload
            // map via getMap(). Walk it to render { schema, data } cleanly.
            val m = c.map
            val obj = org.json.JSONObject()
            (m["schema"] as? String)?.let { obj.put("schema", it) }
            (m["data"]   as? Map<*, *>)?.let {
                @Suppress("UNCHECKED_CAST")
                obj.put("data", org.json.JSONObject(it as Map<String, Any?>))
            }
            ctxsArr.put(obj)
        }
        val envelope = org.json.JSONObject()
            .put("endpoint", endpoint)
            .put("method",   "trackSelfDescribingEvent")
            .put("event", org.json.JSONObject()
                .put("schema", schema)
                .put("data",   org.json.JSONObject(data.mapValues { it.value ?: org.json.JSONObject.NULL })))
            .put("contexts", ctxsArr)
        com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
            "\n─── Snowplow Tracking ───  (convention event=\"$eventName\")\n${envelope.toString(2)}")
    }
}
