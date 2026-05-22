package com.unitrack.sdk

import android.app.Application
import android.content.Context
import com.unitrack.sdk.bridge.NativeBridge
import com.unitrack.sdk.lifecycle.ActivityTracker
import com.unitrack.sdk.lifecycle.AppLifecycleObserver
import com.unitrack.sdk.network.OkHttpTracker
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

    @JvmStatic
    fun initialize(app: Application, config: UniTrackConfig) {
        if (initialized) {
            android.util.Log.w("UniTrack", "already initialized")
            return
        }

        // Load native lib + open core context.
        NativeBridge.load()
        val cfgJson = buildConfigJson(app, config)
        NativeBridge.init(config.apiKey, cfgJson, PLATFORM_ANDROID)

        if (config.autoCapture) {
            if (config.trackScreens) ActivityTracker.install(app)
            if (config.trackTaps)    ClickTracker.install(app)
            if (config.trackNetwork) OkHttpTracker.install()
            AppLifecycleObserver.install(app)
        }

        initialized = true
        NativeBridge.logAppStart(0L)
    }

    @JvmStatic
    fun identify(userId: String, traits: Map<String, Any?> = emptyMap()) {
        NativeBridge.identify(userId, JSONObject(traits).toString())
    }

    @JvmStatic
    fun reset() = NativeBridge.reset()

    @JvmStatic
    @JvmOverloads
    fun track(event: String, properties: Map<String, Any?> = emptyMap()) {
        NativeBridge.track(event, JSONObject(properties).toString())
    }

    @JvmStatic
    fun setScreen(name: String) = NativeBridge.setScreen(name)

    @JvmStatic
    fun flush() = NativeBridge.flush()

    @JvmStatic
    fun setEnabled(enabled: Boolean) = NativeBridge.setEnabled(enabled)

    private fun buildConfigJson(ctx: Context, c: UniTrackConfig): String {
        val obj = JSONObject()
        c.endpoint?.let { obj.put("endpoint", it) }
        obj.put("batch_size",        c.batchSize)
        obj.put("flush_interval_ms", c.flushIntervalMs)
        obj.put("sampling_rate",     c.samplingRate)
        obj.put("auto_capture",      c.autoCapture)
        obj.put("db_path",
                ctx.filesDir.absolutePath + "/unitrack_queue.db")
        return obj.toString()
    }

    internal const val PLATFORM_ANDROID = 2
}
