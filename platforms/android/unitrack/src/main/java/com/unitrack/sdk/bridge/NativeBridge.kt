package com.unitrack.sdk.bridge

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

    fun shutdown() {
        if (ctxPtr != 0L) {
            nativeShutdown(ctxPtr)
            ctxPtr = 0L
        }
    }

    // ─── native declarations ──────────────────────────────────────────────
    private external fun nativeInit(apiKey: String, configJson: String, platform: Int): Long
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
}
