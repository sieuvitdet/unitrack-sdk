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
    /** Raw event names to drop before hitting the collector. Portal
     *  `snowplow.drop_events` — used for SDK-emitted lifecycle events
     *  (app_foreground / app_background / …) when the data team hasn't
     *  published matching iglu schemas, so those events don't become bad rows. */
    private var dropEvents: Set<String> = emptySet(),
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
    fun setDropEvents(names: Collection<String>) { dropEvents = names.toSet() }

    /** Tear down the underlying Snowplow tracker so a re-init (vd portal
     *  pushed a new endpoint) doesn't leak the old tracker. Without this,
     *  Snowplow's Android SDK keeps the tracker registered in its namespace
     *  registry and every event fans out to BOTH the old endpoint AND the
     *  new one. Host calls this on the OLD provider before re-adding a
     *  fresh SnowplowProvider via UniTrack.addProvider. Mirrors iOS
     *  SnowplowProvider.tearDown(). */
    fun tearDown() {
        val t = tracker ?: return
        try { com.snowplowanalytics.snowplow.Snowplow.removeTracker(t) } catch (_: Throwable) {}
        tracker = null
    }

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
        if (name in dropEvents) {
            com.unitrack.sdk.UniTrack.log("UniTrackSnowplow", "SKIP \"$name\" — in snowplow.drop_events")
            return
        }
        // Auto-capture / lifecycle events get routed to the right convention
        // kind so they all share 1 iglu schema parent (vd screen_viewed +
        // screen_exited + screen_load_completed → kind=screen_view → 1 schema).
        // Custom business events (unknown kind) keep 1-to-1 mapping.
        val kind = kindForRawEvent(name) ?: name
        val resolved = eventName(kind, defaultEventNameFor(kind, name))
        val schema = schemaFor(resolved) ?: return
        // Stamp event_action + session_id so every event Snowplow receives
        // carries the join key at the property level (not just inside
        // core_action), letting apps without core_action registered still
        // ship it. session_id là khóa duy nhất join với Portal + provider khác.
        val sid = com.unitrack.sdk.UniTrack.currentSessionId()
        val enriched = properties.toMutableMap().apply {
            if (!containsKey("event_action")) put("event_action", name)
            if (!containsKey("session_id") && sid.isNotEmpty()) put("session_id", sid)
        }
        trackSelfDescribingInternal(schema, resolved, enriched, null, false)
    }

    /** Map raw event names emitted by core / auto-capture / app to a
     *  convention kind so they share 1 iglu schema parent. Returns null
     *  → use the raw name as kind. Mirror of iOS SnowplowProvider.kindForRawEvent. */
    private fun kindForRawEvent(name: String): String? = when (name) {
        "click", "tap" -> "click"
        "screen_view", "screen_viewed", "screen_exited", "screen_load_completed" -> "screen_view"
        "network_request" -> "api"
        "crash", "application_error" -> "crash"
        "session_started", "session_ended", "session_start", "session_end" -> "session"
        else -> null
    }

    /** Default wire name when portal didn't override the kind. */
    private fun defaultEventNameFor(kind: String, raw: String): String = when (kind) {
        "click"       -> "event_click"
        "result"      -> "event_result"
        "screen_view" -> "event_screen_view"
        "crash"       -> "event_crash"
        "api"         -> "event_api"
        "session"     -> "event_session"
        else          -> raw
    }

    override fun setScreen(name: String) {
        // No-op — firing Snowplow's builtin ScreenView(name) here emits a
        // second event under com.snowplowanalytics.mobile/screen_view —
        // duplicating every screen transition alongside UniTrack's own
        // vn.fpt.ftel.snowplow/screen_view (dispatched via
        // track("screen_viewed", ...)). Data team queries the FPT vendor
        // only; the builtin duplicate was pure noise. Method kept as no-op
        // so the AnalyticsProvider protocol still compiles.
        com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
            "setScreen no-op — builtin ScreenView(\"$name\") SUPPRESSED. Convention event fires via track() path.")
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
                              skipGlobalContexts: Boolean,
                              actionName: String? = null): List<SelfDescribingJson> {
        val out = mutableListOf<SelfDescribingJson>()
        if (!skipGlobalContexts) {
            val userSchema = entities["user_context"]?.let { normalizeEntityURI(it) }
            if (userSchema != null && userContext.isNotEmpty()) {
                out.add(SelfDescribingJson(userSchema, stringifyAll(userContext)))
            }
            val coreSchema = entities["core_action"]?.let { normalizeEntityURI(it) }
            if (coreSchema != null) {
                val now = java.time.Instant.now().toString()
                // Prefer the raw event name (screen_viewed / screen_exited /
                // screen_load_completed) over the schema kind (screen_view)
                // so the data team can pivot on core_action.action_name
                // without cracking the event data payload.
                val resolvedActionName = actionName?.takeIf { it.isNotEmpty() } ?: eventName
                val data = mutableMapOf<String, Any?>(
                    "action_name" to resolvedActionName,
                    "timestamp"   to now,
                    // start_time mirrors iOS — the event was created on the
                    // client at this instant. Kept alongside `timestamp` so
                    // existing downstream queries don't break.
                    "start_time"  to now,
                )
                if (!screen.isNullOrEmpty())     data["screen"]      = screen
                if (!elementKey.isNullOrEmpty()) data["element_key"] = elementKey
                // Stamp session_id onto every event — single join key shared
                // with Portal + custom HTTP providers.
                val sid = com.unitrack.sdk.UniTrack.currentSessionId()
                if (sid.isNotEmpty()) data["session_id"] = sid
                out.add(SelfDescribingJson(coreSchema, stringifyAll(data)))
            }
            // application_context — built from the device/app bag UniTrack
            // already collected at init. The SDK fills the common fields;
            // the integrator only registers the schema in portal entities map.
            val appSchema = entities["application_context"]?.let { normalizeEntityURI(it) }
            if (appSchema != null) {
                val bag = com.unitrack.sdk.UniTrack.applicationContext()
                if (bag.isNotEmpty()) {
                    out.add(SelfDescribingJson(appSchema, stringifyAll(bag)))
                }
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

    /**
     * Cast every leaf value in a payload to String so downstream Iglu schemas
     * that declare all fields as string don't reject events into bad-events
     * ("boolean/number found, string expected"). Rules:
     *   • String → unchanged
     *   • Boolean → "true" / "false"
     *   • Number (Int/Long/Double/Float) → decimal string
     *   • Map → recurse, then JSON-serialize to a single string leaf
     *   • Iterable/Array → recurse, then JSON-serialize to a single string leaf
     *   • null → "" (keep key, avoid missing-field surprises)
     *   • Anything else → toString()
     * Called at the last mile before handing data to Snowplow so callers
     * (auto-capture, swizzlers, helpers, host app) don't have to remember.
     */
    private fun stringifyAll(m: Map<String, Any?>): Map<String, String> {
        val out = LinkedHashMap<String, String>(m.size)
        for ((k, v) in m) out[k] = stringifyValue(v)
        return out
    }

    private fun stringifyValue(v: Any?): String = when (v) {
        null       -> ""
        is String  -> v
        is Boolean -> if (v) "true" else "false"
        is Number  -> v.toString()
        is Map<*, *> -> {
            @Suppress("UNCHECKED_CAST")
            val inner = stringifyAll(v as Map<String, Any?>)
            org.json.JSONObject(inner as Map<*, *>).toString()
        }
        is Iterable<*> -> {
            val arr = org.json.JSONArray()
            for (item in v) arr.put(stringifyValue(item))
            arr.toString()
        }
        is Array<*> -> {
            val arr = org.json.JSONArray()
            for (item in v) arr.put(stringifyValue(item))
            arr.toString()
        }
        else -> v.toString()
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
        val filtered = cleanedData(data)
        val screen     = (filtered["screen"]      ?: filtered["screen_name"]) as? String
        val elementKey = (filtered["element_key"] ?: filtered["element"])     as? String
        // `event_action` được stamp trong track() với raw name — dùng nó cho
        // core_action.action_name để phân biệt lifecycle event share cùng schema.
        val rawActionName = filtered["event_action"] as? String
        val ctxs = buildEntities(eventName, screen, elementKey, extra, skipGlobalContexts,
                                 actionName = rawActionName)
        // Stringify at the boundary so ALL Iglu schemas that declare fields
        // as string stop rejecting events into bad-events, no matter what
        // type upstream (auto-capture, swizzlers, host helpers) passed in.
        val cleaned = stringifyAll(filtered)
        val ev = SelfDescribing(SelfDescribingJson(schema, cleaned))
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
        // Prefer the app-configured raw name (screen_viewed / …) so
        // core_action.action_name matches what trackSelfDescribing stamps —
        // otherwise this native ScreenView path fires with action_name="screen_view".
        val rawScreenName = eventName("screen_view", "screen_view")
        sv.entities.addAll(buildEntities("screen_view", screenName, null, null, skipGlobalContexts,
                                         actionName = rawScreenName))
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

    /**
     * Session-lifecycle convention — kind=`session`. Use for session_started /
     * session_ended / any state-of-session event. `action` is the lifecycle
     * verb (started / ended / resumed); `reason` is what triggered the
     * transition (cold_start / backgrounded / timeout / explicit_logout).
     */
    fun trackingSession(action: String,
                        reason: String? = null,
                        durationMs: Int? = null,
                        source: String? = null,
                        data: Map<String, Any?>? = null,
                        extraContexts: List<SelfDescribingJson>? = null,
                        skipGlobalContexts: Boolean = false) {
        val name = eventName("session", "event_session")
        val schema = schemaFor(name) ?: return
        val payload = mutableMapOf<String, Any?>("action" to action)
        if (reason     != null) payload["reason"]      = reason
        if (durationMs != null) payload["duration_ms"] = durationMs
        if (source     != null) payload["source"]      = source
        if (data       != null) payload.putAll(data)
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
                            data: Map<String, *>, contexts: List<SelfDescribingJson>) {
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
        // Screen family gets its own tag so filtering by "SCREEN-VIEW" in
        // logcat isolates exactly the events the data team asks about
        // (screen_viewed / screen_exited / screen_load_completed all share
        // the same "screen_view" schema).
        val eventAction = (data["event_action"] as? String).orEmpty()
        val isScreen = schema.contains("/screen_view/") ||
            eventName == "screen_view" ||
            eventAction.startsWith("screen_")
        val tag = if (isScreen) "SCREEN-VIEW" else "Snowplow Tracking"
        com.unitrack.sdk.UniTrack.log("UniTrackSnowplow",
            "\n─── $tag ───  (convention event=\"$eventName\")\n${envelope.toString(2)}")
    }
}
