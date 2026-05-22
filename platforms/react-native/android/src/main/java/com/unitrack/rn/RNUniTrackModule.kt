package com.unitrack.rn

import android.app.Application
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.UniTrackConfig
import org.json.JSONObject

/**
 * React Native bridge module. Forwards JS calls to the Android
 * UniTrack SDK linked underneath.
 */
class RNUniTrackModule(reactContext: ReactApplicationContext)
    : ReactContextBaseJavaModule(reactContext) {

    override fun getName(): String = "UniTrack"

    @ReactMethod
    fun initialize(apiKey: String, configJson: String, promise: Promise) {
        try {
            val c = runCatching { JSONObject(configJson) }.getOrNull() ?: JSONObject()
            val cfg = UniTrackConfig(
                apiKey            = apiKey,
                endpoint          = c.optString("endpoint").ifBlank { null },
                batchSize         = c.optInt("batchSize", 50),
                flushIntervalMs   = c.optInt("flushIntervalMs", 5000),
                samplingRate      = c.optDouble("samplingRate", 1.0),
                autoCapture       = c.optBoolean("autoCapture", true),
                trackScreens      = c.optBoolean("trackScreens", true),
                trackTaps         = c.optBoolean("trackTaps", true),
                trackNetwork      = c.optBoolean("trackNetwork", true),
            )
            UniTrack.initialize(reactApplicationContext.applicationContext as Application, cfg)
            promise.resolve(null)
        } catch (e: Throwable) {
            promise.reject("INIT_ERROR", e)
        }
    }

    private fun jsonToMap(json: String): Map<String, Any?> {
        val obj = runCatching { JSONObject(json) }.getOrNull() ?: return emptyMap()
        val m = mutableMapOf<String, Any?>()
        for (k in obj.keys()) m[k] = obj.opt(k)
        return m
    }

    @ReactMethod
    fun identify(userId: String, traitsJson: String, promise: Promise) {
        UniTrack.identify(userId, jsonToMap(traitsJson)); promise.resolve(null)
    }

    @ReactMethod
    fun reset(promise: Promise) { UniTrack.reset(); promise.resolve(null) }

    @ReactMethod
    fun track(event: String, propsJson: String, promise: Promise) {
        UniTrack.track(event, jsonToMap(propsJson)); promise.resolve(null)
    }

    @ReactMethod
    fun setScreen(name: String, promise: Promise) {
        UniTrack.setScreen(name); promise.resolve(null)
    }

    @ReactMethod
    fun flush(promise: Promise) { UniTrack.flush(); promise.resolve(null) }

    @ReactMethod
    fun setEnabled(enabled: Boolean, promise: Promise) {
        UniTrack.setEnabled(enabled); promise.resolve(null)
    }
}
