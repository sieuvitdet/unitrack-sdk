package com.unitrack.sdk

import com.unitrack.sdk.bridge.NativeBridge
import org.json.JSONException
import org.json.JSONObject

/**
 * Safe JSON parsing wrapper. Reports parse failures to the SDK with
 * type, error, and a short data preview.
 *
 * Usage:
 *
 *     val obj = UniTrackJson.parse("MyDTO", rawString)
 *
 * For Gson / Moshi / kotlinx.serialization, wrap your own decode call
 * in a try/catch and call [logError] in the catch block.
 */
object UniTrackJson {

    @JvmStatic
    fun parse(targetType: String, raw: String): JSONObject? {
        return try {
            JSONObject(raw)
        } catch (e: JSONException) {
            logError(targetType, e, raw)
            null
        }
    }

    @JvmStatic
    fun logError(targetType: String, error: Throwable, data: String) {
        NativeBridge.logJsonError(
            type    = targetType,
            error   = error.javaClass.simpleName + ": " + error.message.orEmpty(),
            stack   = error.stackTraceToString().lines().take(8)
                          .joinToString("\n"),
            preview = data.take(200)
        )
    }
}
