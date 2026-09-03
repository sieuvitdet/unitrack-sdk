package com.unitrack.sdk.network

import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.bridge.NativeBridge
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.IOException

/**
 * OkHttp interceptor for automatic network tracking.
 *
 * Because OkHttp doesn't have a global hook, partners must either:
 *   (a) Use [attach] to add the interceptor to their existing client, or
 *   (b) Let the SDK install a default singleton via [install].
 *
 * Most apps build their own OkHttpClient; reflection-based interception
 * isn't reliable across versions. The [attach] one-liner is the
 * pragmatic approach.
 */
object OkHttpTracker {

    /**
     * Wraps an existing OkHttpClient and returns a new client with
     * UniTrack's interceptor attached. Usage:
     *
     *     val client = OkHttpTracker.attach(myClient)
     */
    @JvmStatic
    fun attach(client: OkHttpClient): OkHttpClient =
        client.newBuilder().addInterceptor(TrackingInterceptor()).build()

    /**
     * Called automatically when `trackNetwork = true` and OkHttp is on
     * the classpath. This is a no-op on its own; the partner must call
     * [attach] for their custom clients. We log a message hinting at
     * the usage.
     */
    @JvmStatic
    fun install() {
        android.util.Log.i("UniTrack",
            "OkHttp tracking ready — call OkHttpTracker.attach(client)")
    }

    private class TrackingInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val req = chain.request()
            // elapsedRealtime: đồng hồ đơn điệu. Wall clock nhảy giữa lúc
            // request đang bay làm durationMs ra âm.
            val started = android.os.SystemClock.elapsedRealtime()
            val reqBytes = req.body?.contentLength() ?: 0L
            var status   = 0
            var respBytes = 0L
            var error    = ""

            return try {
                val resp = chain.proceed(req)
                status   = resp.code
                respBytes = resp.body?.contentLength() ?: 0L
                resp
            } catch (e: IOException) {
                error = e.javaClass.simpleName + ": " + e.message.orEmpty()
                throw e
            } finally {
                val dur = maxOf(0L, android.os.SystemClock.elapsedRealtime() - started)
                NativeBridge.logNetwork(
                    url        = req.url.toString().substringBefore('?'),
                    method     = req.method,
                    status     = status,
                    durationMs = dur,
                    reqBytes   = reqBytes,
                    respBytes  = respBytes,
                    error      = error
                )
            }
        }
    }
}
