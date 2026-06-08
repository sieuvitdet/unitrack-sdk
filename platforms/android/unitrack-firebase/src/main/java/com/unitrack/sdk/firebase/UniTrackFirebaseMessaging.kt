package com.unitrack.sdk.firebase

import com.unitrack.sdk.UniTrack

/**
 * Helpers app calls from its existing FirebaseMessagingService / notification
 * handlers to fan FCM token + push events into UniTrack (and from there to
 * Snowplow + the portal).
 *
 * We deliberately don't take over MessagingService: every app worth migrating
 * already owns one (FPT Life keeps the FCM token in their backend, handles
 * notification routing, etc.). Forcing a swizzle/proxy here would conflict
 * with that. Apps keep their service and add 1 line per callback.
 *
 * Usage in MyFirebaseMessagingService:
 *
 *   override fun onNewToken(token: String) {
 *       UniTrackFirebaseMessaging.handleTokenUpdate(token)
 *   }
 *
 *   override fun onMessageReceived(message: RemoteMessage) {
 *       UniTrackFirebaseMessaging.handleMessageReceived(message)
 *   }
 *
 *   // Trong notification-click receiver (tùy app):
 *   UniTrackFirebaseMessaging.handleNotificationClicked(intent.extras)
 *
 * Parity with iOS UniTrackFirebaseMessaging. When firebase-messaging isn't
 * linked, FCM RemoteMessage class won't be on the classpath — calls compile
 * away because the helper uses `Any?` parameter type for raw bundles.
 */
object UniTrackFirebaseMessaging {

    @Volatile private var cachedToken: String? = null

    /** Latest FCM token observed. null until [handleTokenUpdate] fires once. */
    @JvmStatic
    fun currentToken(): String? = cachedToken

    /** Call from FirebaseMessagingService.onNewToken. Fires
     *  `fcm_token_updated` only when the token actually changes (Firebase
     *  echoes the same token on every cold start). */
    @JvmStatic
    fun handleTokenUpdate(token: String?) {
        val prev = cachedToken
        cachedToken = token
        if (token.isNullOrEmpty() || token == prev) return
        val props = mutableMapOf<String, Any?>("fcm_token" to token)
        if (!prev.isNullOrEmpty()) props["prev_token"] = prev
        UniTrack.track("fcm_token_updated", props)
    }

    /** Call from FirebaseMessagingService.onMessageReceived. Fires
     *  `notification` event with state=foreground/background, action=received.
     *  Pass the FCM RemoteMessage as Any so this file doesn't require
     *  firebase-messaging at compile time.
     *
     *  Recommended call site:
     *    UniTrackFirebaseMessaging.handleMessageReceived(remoteMessage)
     */
    @JvmStatic
    fun handleMessageReceived(remoteMessage: Any?) {
        val data = extractDataFromRemoteMessage(remoteMessage)
        val notif = extractNotificationFromRemoteMessage(remoteMessage)
        val notifId = data["gcm.message_id"]?.toString()
            ?: data["google.message_id"]?.toString()
            ?: ""
        UniTrack.trackNotification(
            state = "background",       // FCM onMessageReceived fires when app in bg/silent
            action = "received",
            title = notif["title"]?.toString(),
            body = notif["body"]?.toString(),
            notificationId = notifId,
            data = data,
        )
    }

    /** Call when user taps a push notification — typically from the Activity
     *  launched by the notification's PendingIntent. Pass `intent.extras`. */
    @JvmStatic
    fun handleNotificationClicked(extras: android.os.Bundle?) {
        if (extras == null) return
        val data = mutableMapOf<String, Any?>()
        for (key in extras.keySet()) {
            data[key] = extras.get(key)?.toString()
        }
        val notifId = data["gcm.message_id"]?.toString()
            ?: data["google.message_id"]?.toString()
            ?: ""
        UniTrack.trackNotification(
            state = "foreground",
            action = "clicked",
            title = data["title"]?.toString() ?: data["gcm.notification.title"]?.toString(),
            body = data["body"]?.toString() ?: data["gcm.notification.body"]?.toString(),
            notificationId = notifId,
            data = data,
        )
    }

    // ── Reflection-based extractors (avoid hard compile-time dep on FCM) ──

    private fun extractDataFromRemoteMessage(msg: Any?): Map<String, Any?> {
        if (msg == null) return emptyMap()
        return runCatching {
            // RemoteMessage.getData(): Map<String, String>
            val method = msg.javaClass.getMethod("getData")
            @Suppress("UNCHECKED_CAST")
            (method.invoke(msg) as? Map<String, String>)?.toMap()
        }.getOrNull() ?: emptyMap()
    }

    private fun extractNotificationFromRemoteMessage(msg: Any?): Map<String, Any?> {
        if (msg == null) return emptyMap()
        return runCatching {
            // RemoteMessage.getNotification() returns RemoteMessage.Notification
            val notif = msg.javaClass.getMethod("getNotification").invoke(msg) ?: return emptyMap()
            val title = runCatching { notif.javaClass.getMethod("getTitle").invoke(notif) as? String }.getOrNull()
            val body  = runCatching { notif.javaClass.getMethod("getBody").invoke(notif)  as? String }.getOrNull()
            buildMap {
                if (title != null) put("title", title)
                if (body  != null) put("body",  body)
            }
        }.getOrNull() ?: emptyMap()
    }
}
