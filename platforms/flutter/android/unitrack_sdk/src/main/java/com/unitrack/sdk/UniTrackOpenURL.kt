package com.unitrack.sdk

import android.content.Context
import android.content.Intent
import android.net.Uri

/**
 * Drop-in third-party open auto-capture for Android.
 *
 * Android doesn't give the SDK a central hook for outgoing intents — every
 * `startActivity(Intent(ACTION_VIEW, uri))` call is direct from the app, and
 * the most popular Flutter plugin (url_launcher) does the same under its
 * platform channel.
 *
 * Two integration styles:
 *
 *   1) Replace your `startActivity(Intent(ACTION_VIEW, uri))` calls with:
 *        UniTrackOpenURL.open(context, uri)
 *      → the helper fires `third_party_open` then starts the intent.
 *
 *   2) If you can't centralise the call site, classify + log explicitly:
 *        UniTrackOpenURL.log(uri)
 *        startActivity(Intent(ACTION_VIEW, uri))
 *
 * The classification matches iOS (`UniTrackOpenURL.classify`) so the portal
 * groups "user opened Zalo" the same way on both platforms.
 */
object UniTrackOpenURL {

    /// Fire `third_party_open` AND start the Intent.ACTION_VIEW intent.
    /// Returns true if the start succeeded.
    @JvmStatic
    fun open(context: Context, uri: Uri): Boolean {
        log(uri)
        return runCatching {
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    /// Just log without starting the intent — for call sites that already
    /// fire startActivity themselves.
    @JvmStatic
    fun log(uri: Uri) {
        val url = uri.toString()
        UniTrack.track("third_party_open", mapOf(
            "target" to classify(uri),
            "url"    to url,
            "scheme" to (uri.scheme ?: ""),
        ))
    }

    /// Same categorisation as iOS UniTrackOpenURL.classify so cross-platform
    /// queries group by the same target tag.
    @JvmStatic
    fun classify(uri: Uri): String = when (val s = uri.scheme?.lowercase()) {
        "http", "https" -> "browser"
        "tel"           -> "phone"
        "mailto"        -> "mail"
        "sms"           -> "sms"
        null, ""        -> "unknown"
        else            -> s
    }
}
