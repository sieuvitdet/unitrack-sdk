package com.unitrack.flutter

import android.app.Application
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.UniTrackConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject

class UniTrackPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var app: Application? = null
    // Main-thread handler for invoking the onFlushCompleted callback back into
    // Flutter — the native callback fires on the SDK worker thread but
    // MethodChannel.invokeMethod must be called from the platform main thread.
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "unitrack")
        channel.setMethodCallHandler(this)
        app = binding.applicationContext as? Application
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Clear native callback so we don't leak the previous channel ref into
        // a new Flutter engine (vd hot-restart re-attaches).
        runCatching { UniTrack.onFlushCompleted(null) }
        channel.setMethodCallHandler(null)
    }

    private fun jsonToMap(json: String?): Map<String, Any?> {
        if (json.isNullOrBlank()) return emptyMap()
        val obj = runCatching { JSONObject(json) }.getOrNull() ?: return emptyMap()
        val m = mutableMapOf<String, Any?>()
        for (k in obj.keys()) m[k] = obj.opt(k)
        return m
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                val a = app ?: run {
                    result.error("NO_APP", "Application context unavailable", null)
                    return
                }
                val apiKey = call.argument<String>("apiKey") ?: ""
                val cfgJson = call.argument<String>("config")
                val c = runCatching { JSONObject(cfgJson ?: "{}") }.getOrNull() ?: JSONObject()
                val cfg = UniTrackConfig(
                    apiKey          = apiKey,
                    endpoint        = c.optString("endpoint").ifBlank { null },
                    batchSize       = c.optInt("batchSize", 50),
                    flushIntervalMs = c.optInt("flushIntervalMs", 5000),
                    samplingRate    = c.optDouble("samplingRate", 1.0),
                    autoCapture     = c.optBoolean("autoCapture", true),
                    trackScreens    = c.optBoolean("trackScreens", true),
                    trackTaps       = c.optBoolean("trackTaps", true),
                    trackNetwork    = c.optBoolean("trackNetwork", true),
                    journeyCapture  = c.optBoolean("journeyCapture", true),
                    sessionTimeoutMs = c.optInt("sessionTimeoutMs", 1_800_000),
                    screenLoadEvent = c.optString("screenLoadEvent", "screen_load_completed"),
                )
                UniTrack.initialize(a, cfg)

                // After initialize(), the native SDK has already popped the
                // recovered crash and fanned it out to native providers (if
                // any). Forward the same JSON up to Dart so Dart-side
                // providers also see it. Single-shot drain.
                val recoveredJson = UniTrack.takeRecoveredCrashJsonForFlutter()
                if (recoveredJson.isNotEmpty()) {
                    channel.invokeMethod("onRecoveredCrash", mapOf("props" to recoveredJson))
                }
                result.success(null)
            }
            "identify" -> {
                UniTrack.identify(
                    call.argument<String>("userId") ?: "",
                    jsonToMap(call.argument<String>("traits"))
                )
                result.success(null)
            }
            "reset"      -> { UniTrack.reset(); result.success(null) }
            "track" -> {
                UniTrack.track(
                    call.argument<String>("event") ?: "",
                    jsonToMap(call.argument<String>("props"))
                )
                result.success(null)
            }
            "setScreen"  -> {
                UniTrack.setScreen(call.argument<String>("name") ?: "")
                result.success(null)
            }
            "flush"      -> { UniTrack.flush(); result.success(null) }
            "setEnabled" -> {
                UniTrack.setEnabled(call.argument<Boolean>("enabled") ?: true)
                result.success(null)
            }

            // ── Session API parity with iOS / Android Kotlin ──────────────
            "currentSessionId"  -> result.success(UniTrack.currentSessionId())
            "sessionIndex"      -> result.success(UniTrack.sessionIndex())
            "previousSessionId" -> result.success(UniTrack.previousSessionId())
            "rotateSession"     -> { UniTrack.rotateSession(); result.success(null) }

            // Offline queue snapshot by event_name. Returned as a Map<String,Int>
            // which the standard Flutter codec encodes as a Dart Map.
            "pendingEventCounts" -> result.success(UniTrack.pendingEventCounts())

            // Subscribe / unsubscribe the flush-success callback. Dart side
            // passes `enabled: true` after registering its onFlushCompleted
            // listener and `false` when clearing.
            "setFlushCallbackEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                if (enabled) {
                    UniTrack.onFlushCompleted { counts ->
                        // Hop to main; MethodChannel is not thread-safe off it.
                        mainHandler.post {
                            channel.invokeMethod("onFlushCompleted", mapOf("counts" to counts))
                        }
                    }
                } else {
                    UniTrack.onFlushCompleted(null)
                }
                result.success(null)
            }

            // Device/app metadata bag — same Snowplow application_context the
            // native provider builds. Cached at init; empty before then.
            "applicationContext" -> result.success(UniTrack.applicationContext())

            // Remote config resolver — looks up portal sdk_config.custom_values
            // first, then any RemoteValueProvider (Firebase) registered, then
            // returns null so the Dart side can fall back to its default.
            // Type is hinted by the caller so we route to the correctly-typed
            // Kotlin overload (Dart only sees the resolved value).
            "getRemoteValue" -> {
                val key  = call.argument<String>("key") ?: ""
                val kind = call.argument<String>("type") ?: "string"
                when (kind) {
                    "bool"   -> result.success(UniTrack.getRemoteBoolean(key, false))
                    "int"    -> result.success(UniTrack.getRemoteInt(key, 0))
                    "long"   -> result.success(UniTrack.getRemoteLong(key, 0L))
                    "double" -> result.success(UniTrack.getRemoteDouble(key, 0.0))
                    else     -> result.success(UniTrack.getRemoteString(key, ""))
                }
            }

            // Session-stat sidebag — apps the binding tracks count/error/crash
            // for so session_ended payloads carry it without a separate state.
            "sessionScreenCount" -> result.success(UniTrack.sessionScreenCount())
            "sessionHadError"    -> result.success(UniTrack.sessionHadError())
            "sessionHadCrash"    -> result.success(UniTrack.sessionHadCrash())
            "incrementScreenCount" -> { UniTrack.incrementScreenCount(); result.success(null) }
            "markSessionError"     -> { UniTrack.markSessionError();     result.success(null) }
            "markSessionCrash"     -> { UniTrack.markSessionCrash();     result.success(null) }
            "resetSessionStats"    -> { UniTrack.resetSessionStats();    result.success(null) }

            else -> result.notImplemented()
        }
    }
}
