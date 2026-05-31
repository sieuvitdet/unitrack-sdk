package com.unitrack.sdk.bridge

import android.util.Log
import androidx.annotation.Keep
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

// @Keep: the C JNI side (JNI_OnLoad in jni_bridge.cpp) looks up `httpPost` and
// `parseHeaders` by name via GetStaticMethodID, so R8/ProGuard MUST NOT rename
// or remove this class or any of its members. Without @Keep, release builds
// minify `httpPost` to `d` and JNI_OnLoad throws NoSuchMethodError, which
// crashes the app the first time NativeBridge.load() runs.
@Keep
object NativeBridge {

    @Volatile private var loaded = false
    @Volatile private var ctxPtr: Long = 0L

    @Synchronized
    fun load() {
        if (loaded) return
        System.loadLibrary("unitrack_jni")
        loaded = true
    }

    fun init(apiKey: String, configJson: String, platform: Int) {
        ctxPtr = nativeInit(apiKey, configJson, platform)
        // The native core is built WITHOUT libcurl, so it has no way to send
        // HTTP on its own — install a Kotlin transport (HttpURLConnection) that
        // the core calls back into to upload each event batch. Without this,
        // every event is silently dropped ("no HTTP callback installed").
        if (ctxPtr != 0L) nativeInstallHttp(ctxPtr)
    }

    /**
     * HTTP transport called BY the native core (via JNI) to upload an event
     * batch. Runs on the core's flush thread. Returns the HTTP status code, or
     * 0 on a transport failure (so the core keeps the batch and retries).
     *
     * @param headersJson e.g. {"Content-Type":"application/json","Authorization":"Bearer ..."}
     */
    @JvmStatic
    fun httpPost(url: String, headersJson: String, body: ByteArray): Int {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15000
                readTimeout = 15000
                doOutput = true
                // Parse the simple flat {"k":"v"} headers object.
                parseHeaders(headersJson).forEach { (k, v) -> setRequestProperty(k, v) }
            }
            conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            // Drain so the connection can be reused/closed cleanly.
            try {
                (if (code in 200..299) conn.inputStream else conn.errorStream)
                    ?.let { s -> BufferedReader(InputStreamReader(s)).use { it.readText() } }
            } catch (_: Throwable) {}
            Log.i("UniTrack", "httpPost $url -> $code (${body.size}b)")
            code
        } catch (e: Throwable) {
            Log.w("UniTrack", "httpPost failed: $url : ${e.message}")
            0
        } finally {
            conn?.disconnect()
        }
    }

    private fun parseHeaders(json: String): Map<String, String> {
        return try {
            val o = org.json.JSONObject(json)
            buildMap { o.keys().forEach { k -> put(k, o.optString(k)) } }
        } catch (_: Throwable) { emptyMap() }
    }

    fun identify(userId: String, traitsJson: String)        = nativeIdentify(ctxPtr, userId, traitsJson)
    fun reset()                                             = nativeReset(ctxPtr)
    fun track(event: String, propsJson: String)             = nativeTrack(ctxPtr, event, propsJson)
    fun setScreen(name: String)                             = nativeSetScreen(ctxPtr, name)
    fun flush()                                             = nativeFlush(ctxPtr)
    fun setEnabled(enabled: Boolean)                        = nativeSetEnabled(ctxPtr, enabled)
    fun setDeviceInfo(deviceJson: String)                   = nativeSetDeviceInfo(ctxPtr, deviceJson)

    fun logTap(elementKey: String, screen: String, extraJson: String) =
        nativeLogTap(ctxPtr, elementKey, screen, extraJson)

    fun logNetwork(url: String, method: String, status: Int,
                   durationMs: Long, reqBytes: Long, respBytes: Long, error: String) =
        nativeLogNetwork(ctxPtr, url, method, status, durationMs, reqBytes, respBytes, error)

    fun logJsonError(type: String, error: String, stack: String, preview: String) =
        nativeLogJsonError(ctxPtr, type, error, stack, preview)

    fun logMemoryWarning(used: Long, limit: Long, screen: String) =
        nativeLogMemoryWarning(ctxPtr, used, limit, screen)

    fun logCrash(crashJson: String)  = nativeLogCrash(ctxPtr, crashJson)
    fun logForeground()              = nativeLogForeground(ctxPtr)
    fun logBackground()              = nativeLogBackground(ctxPtr)
    fun logAppStart(coldStartMs: Long) = nativeLogAppStart(ctxPtr, coldStartMs)

    /**
     * W3C distributed-tracing helper. Returns Pair(traceId, spanId) — both
     * lowercase hex (trace_id 32 chars, span_id 16 chars). Pure native call,
     * does NOT require ctxPtr to be initialized, so an OkHttp interceptor
     * installed in Application.onCreate can call this safely even before
     * UniTrack.init() finishes.
     */
    fun newTrace(): Pair<String, String> {
        // Make sure libunitrack_jni is loaded — apps may install the
        // interceptor before NativeBridge.init() runs.
        if (!loaded) load()
        val pair = nativeNewTrace()
        return Pair(pair[0], pair[1])
    }

    fun shutdown() {
        if (ctxPtr != 0L) {
            nativeShutdown(ctxPtr)
            ctxPtr = 0L
        }
    }

    // ─── native declarations ──────────────────────────────────────────────
    private external fun nativeInit(apiKey: String, configJson: String, platform: Int): Long
    private external fun nativeInstallHttp(ctx: Long)
    private external fun nativeShutdown(ctx: Long)
    private external fun nativeFlush(ctx: Long)
    private external fun nativeIdentify(ctx: Long, userId: String, traitsJson: String)
    private external fun nativeReset(ctx: Long)
    private external fun nativeTrack(ctx: Long, event: String, propsJson: String)
    private external fun nativeSetScreen(ctx: Long, name: String)
    private external fun nativeSetEnabled(ctx: Long, enabled: Boolean)
    private external fun nativeSetDeviceInfo(ctx: Long, deviceJson: String)
    private external fun nativeLogTap(ctx: Long, key: String, screen: String, extra: String)
    private external fun nativeLogNetwork(ctx: Long, url: String, method: String,
                                          status: Int, durationMs: Long,
                                          reqBytes: Long, respBytes: Long, error: String)
    private external fun nativeLogJsonError(ctx: Long, type: String, error: String,
                                            stack: String, preview: String)
    private external fun nativeLogMemoryWarning(ctx: Long, used: Long, limit: Long, screen: String)
    private external fun nativeLogCrash(ctx: Long, crashJson: String)
    private external fun nativeLogForeground(ctx: Long)
    private external fun nativeLogBackground(ctx: Long)
    private external fun nativeLogAppStart(ctx: Long, coldStartMs: Long)
    // length-2 result: [traceId 32-hex, spanId 16-hex]
    private external fun nativeNewTrace(): Array<String>
}
