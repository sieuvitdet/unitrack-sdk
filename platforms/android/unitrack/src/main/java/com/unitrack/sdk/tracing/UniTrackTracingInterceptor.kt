package com.unitrack.sdk.tracing

import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.bridge.NativeBridge
import okhttp3.Interceptor
import okhttp3.Response

/**
 * OkHttp interceptor that injects the W3C `traceparent` header on outbound
 * HTTP calls, so backend logs and the network_request event the SDK emits
 * share a single trace_id.
 *
 * Install once on the app's shared OkHttp client (BEFORE network interceptors
 * that depend on auth tokens — those mutate the header set and we don't want
 * to race them):
 *
 *     OkHttpClient.Builder()
 *         .addInterceptor(UniTrackTracingInterceptor())
 *         .addInterceptor(AuthInterceptor())
 *         .build()
 *
 * Behavior is driven by [UniTrack.setTracing]: disabled ⇒ pass-through; host
 * not on the allowlist ⇒ pass-through; header already present on the request
 * ⇒ pass-through (an upstream component is propagating its own trace, don't
 * clobber it).
 *
 * Note: OkHttp is a `compileOnly` dependency of the UniTrack module. This
 * class only compiles into your APK if the app already brings OkHttp in.
 */
class UniTrackTracingInterceptor : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val req = chain.request()
        val snap = UniTrack.tracingSnapshot()
        if (!snap.enabled) return chain.proceed(req)

        // Respect upstream propagation: if something already set the header,
        // don't overwrite — that's another tracing tool (or a manual call).
        if (req.header(snap.headerName) != null) return chain.proceed(req)

        // Honor UniTrack.excludeFromNetworkCapture(...): if the request URL
        // matches a registered substring (case-insensitive), skip trace
        // injection too — providers register their own collector hosts here
        // and we should not propagate trace headers into them.
        val urlLc = req.url.toString().lowercase()
        val exclusions = UniTrack.networkExclusions
        for (i in exclusions.indices) {
            if (urlLc.contains(exclusions[i].lowercase())) {
                return chain.proceed(req)
            }
        }

        if (!UniTrack.shouldInjectTrace(req.url.host, snap.allowlist)) {
            return chain.proceed(req)
        }

        val (traceId, spanId) = NativeBridge.newTrace()
        val flags = if (snap.sampled) "01" else "00"
        val tagged = req.newBuilder()
            .addHeader(snap.headerName, "00-$traceId-$spanId-$flags")
            // Tag the OkHttp request with the ids so an app-side tracker
            // (e.g. Retrofit error reporter) can read them off the response.
            .tag(TraceIds::class.java, TraceIds(traceId, spanId))
            .build()
        return chain.proceed(tagged)
    }

    /** Trace ids attached to the OkHttp Request via Request.tag(TraceIds). */
    data class TraceIds(val traceId: String, val spanId: String)
}
