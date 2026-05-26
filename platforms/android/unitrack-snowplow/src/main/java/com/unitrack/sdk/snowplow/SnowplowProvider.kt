package com.unitrack.sdk.snowplow

import android.app.Application
import android.util.Log
import com.snowplowanalytics.snowplow.Snowplow
import com.snowplowanalytics.snowplow.configuration.NetworkConfiguration
import com.snowplowanalytics.snowplow.configuration.TrackerConfiguration
import com.snowplowanalytics.snowplow.controller.TrackerController
import com.snowplowanalytics.snowplow.event.ScreenView
import com.snowplowanalytics.snowplow.event.SelfDescribing
import com.snowplowanalytics.snowplow.event.Structured
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
) : AnalyticsProvider {

    private var tracker: TrackerController? = null

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
        Log.i("UniTrackSnowplow", "tracker ready ($endpoint, appId=$appId, lifecycle=${options.lifecycleAutotracking})")
    }

    fun updateUserContext(ctx: Map<String, Any?>) { userContext = ctx }

    private fun entities(): List<SelfDescribingJson> {
        val ctx = userContext ?: return emptyList()
        val schema = userContextSchema ?: return emptyList()
        return listOf(SelfDescribingJson(schema, ctx.mapValues { it.value ?: "" }))
    }

    override fun track(name: String, properties: Map<String, Any?>) {
        val t = tracker ?: return
        val schema = schemas[name]
        val event = if (schema != null) {
            SelfDescribing(SelfDescribingJson(schema, properties.mapValues { it.value ?: "" }))
        } else {
            Structured("unitrack", name).apply {
                label = (properties["screen"] ?: properties["screen_name"])?.toString()
                property = (properties["element_key"] ?: properties["state"])?.toString()
            }
        }
        event.customContexts.addAll(entities())
        t.track(event)
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
        sv.customContexts.addAll(entities())
        t.track(sv)
    }
}
