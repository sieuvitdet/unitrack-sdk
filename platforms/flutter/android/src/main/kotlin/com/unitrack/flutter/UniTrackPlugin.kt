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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "unitrack")
        channel.setMethodCallHandler(this)
        app = binding.applicationContext as? Application
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
                )
                UniTrack.initialize(a, cfg)
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
            else -> result.notImplemented()
        }
    }
}
