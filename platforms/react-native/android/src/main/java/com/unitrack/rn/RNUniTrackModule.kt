package com.unitrack.rn

import android.app.Application
import android.os.Handler
import android.os.Looper
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
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
                journeyCapture    = c.optBoolean("journeyCapture", true),
                sessionTimeoutMs  = c.optInt("sessionTimeoutMs", 1_800_000),
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

    // ── Session API parity with iOS / Android Kotlin facade ──────────────
    @ReactMethod
    fun currentSessionId(promise: Promise) {
        promise.resolve(UniTrack.currentSessionId())
    }

    @ReactMethod
    fun sessionIndex(promise: Promise) {
        // RN bridge encodes Long as Double in JS; truncate to Int to match
        // iOS (UniTrack.sessionIndex() returns Int there). Counters are
        // small enough that this is lossless.
        promise.resolve(UniTrack.sessionIndex().toInt())
    }

    @ReactMethod
    fun previousSessionId(promise: Promise) {
        promise.resolve(UniTrack.previousSessionId())
    }

    @ReactMethod
    fun rotateSession(promise: Promise) {
        UniTrack.rotateSession(); promise.resolve(null)
    }

    // ── Offline queue + flush callback ────────────────────────────────────
    @ReactMethod
    fun pendingEventCounts(promise: Promise) {
        val counts = UniTrack.pendingEventCounts()
        val out: WritableMap = Arguments.createMap()
        counts.forEach { (k, v) -> out.putInt(k, v) }
        promise.resolve(out)
    }

    @ReactMethod
    fun setFlushCallbackEnabled(enabled: Boolean, promise: Promise) {
        if (enabled) {
            UniTrack.onFlushCompleted { counts ->
                // SDK fires from a worker thread. Hop to main + emit via the
                // DeviceEventManagerModule (RN's standard event bus). JS side
                // subscribes via `NativeEventEmitter(NativeModules.UniTrack)
                // .addListener('onFlushCompleted', …)`.
                mainHandler.post {
                    val body = Arguments.createMap().apply {
                        val inner = Arguments.createMap()
                        counts.forEach { (k, v) -> inner.putInt(k, v) }
                        putMap("counts", inner)
                    }
                    reactApplicationContext
                        .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
                        ?.emit("onFlushCompleted", body)
                }
            }
        } else {
            UniTrack.onFlushCompleted(null)
        }
        promise.resolve(null)
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Application context + remote values ───────────────────────────────
    @ReactMethod
    fun applicationContext(promise: Promise) {
        val bag = UniTrack.applicationContext()
        // The bag may carry non-WritableMap-friendly types (vd Float); coerce
        // primitives explicitly so RN's codec doesn't choke.
        val out: WritableMap = Arguments.createMap()
        bag.forEach { (k, v) ->
            when (v) {
                null       -> out.putNull(k)
                is Boolean -> out.putBoolean(k, v)
                is Int     -> out.putInt(k, v)
                is Long    -> out.putDouble(k, v.toDouble())
                is Float   -> out.putDouble(k, v.toDouble())
                is Double  -> out.putDouble(k, v)
                is String  -> out.putString(k, v)
                else       -> out.putString(k, v.toString())
            }
        }
        promise.resolve(out)
    }

    @ReactMethod
    fun getRemoteValue(key: String, type: String, promise: Promise) {
        when (type) {
            "bool"   -> promise.resolve(UniTrack.getRemoteBoolean(key, false))
            "int"    -> promise.resolve(UniTrack.getRemoteInt(key, 0))
            "long"   -> promise.resolve(UniTrack.getRemoteLong(key, 0L).toDouble())
            "double" -> promise.resolve(UniTrack.getRemoteDouble(key, 0.0))
            else     -> promise.resolve(UniTrack.getRemoteString(key, ""))
        }
    }

    // ── Session-stat sidebag ──────────────────────────────────────────────
    @ReactMethod
    fun sessionScreenCount(promise: Promise) { promise.resolve(UniTrack.sessionScreenCount()) }
    @ReactMethod
    fun sessionHadError(promise: Promise)    { promise.resolve(UniTrack.sessionHadError()) }
    @ReactMethod
    fun sessionHadCrash(promise: Promise)    { promise.resolve(UniTrack.sessionHadCrash()) }
    @ReactMethod
    fun incrementScreenCount(promise: Promise) { UniTrack.incrementScreenCount(); promise.resolve(null) }
    @ReactMethod
    fun markSessionError(promise: Promise)     { UniTrack.markSessionError();     promise.resolve(null) }
    @ReactMethod
    fun markSessionCrash(promise: Promise)     { UniTrack.markSessionCrash();     promise.resolve(null) }
    @ReactMethod
    fun resetSessionStats(promise: Promise)    { UniTrack.resetSessionStats();    promise.resolve(null) }

    // ── EventEmitter glue (required by RN's NativeEventEmitter API) ──────
    @ReactMethod
    fun addListener(eventName: String) { /* no-op; required by NativeEventEmitter */ }
    @ReactMethod
    fun removeListeners(count: Int)    { /* no-op */ }
}
