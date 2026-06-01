package com.unitrack.sdk

/**
 * Drop-in notification auto-capture for Android. The app forwards its FCM /
 * local notification callbacks here ONCE and UniTrack logs them — no manual
 * per-notification `trackNotification` calls.
 *
 * Firebase Cloud Messaging:
 *
 *     class MyMessagingService : FirebaseMessagingService() {
 *         override fun onMessageReceived(msg: RemoteMessage) {
 *             UniTrackNotifications.captureFcm(
 *                 hasNotificationPayload = msg.notification != null,
 *                 isAppForeground = UniTrackNotifications.isAppForeground(),
 *                 title = msg.notification?.title,
 *                 body  = msg.notification?.body,
 *             )
 *             // ... your handling ...
 *         }
 *     }
 *
 * When a user taps a notification, call [captureOpened] from the launched
 * Activity (e.g. from intent extras you attached when posting it).
 */
object UniTrackNotifications {

    /**
     * Log a received notification, deriving state automatically:
     *  - no visible payload (data-only)  -> "silent"
     *  - app in foreground               -> "foreground"
     *  - otherwise                       -> "background"
     *
     * [messageId] is RemoteMessage.getMessageId() — passing it lets the
     * portal dedup the same push delivered + opened. [data] is RemoteMessage
     * .getData() — usually the routing keys (deeplink/campaign_id) the app
     * cares about; without it the analytics is blind to push intent.
     */
    @JvmStatic @JvmOverloads
    fun captureFcm(
        hasNotificationPayload: Boolean,
        isAppForeground: Boolean,
        title: String? = null,
        body: String? = null,
        messageId: String? = null,
        data: Map<String, String>? = null,
    ) {
        val state = when {
            !hasNotificationPayload -> "silent"
            isAppForeground         -> "foreground"
            else                    -> "background"
        }
        UniTrack.trackNotification(state, "received", title, body, messageId, data)
    }

    /** Log that the user opened/tapped a notification. */
    @JvmStatic @JvmOverloads
    fun captureOpened(
        title: String? = null,
        body: String? = null,
        messageId: String? = null,
        data: Map<String, String>? = null,
    ) {
        // An opened notification was, by definition, displayed to the user.
        val state = if (isAppForeground()) "foreground" else "background"
        UniTrack.trackNotification(state, "opened", title, body, messageId, data)
    }

    /** Log that the user dismissed a notification (swiped away without opening). */
    @JvmStatic @JvmOverloads
    fun captureDismissed(
        title: String? = null,
        body: String? = null,
        messageId: String? = null,
    ) {
        // Dismissal happens regardless of app state — record the current one.
        val state = if (isAppForeground()) "foreground" else "background"
        UniTrack.trackNotification(state, "dismissed", title, body, messageId, null)
    }

    /**
     * Best-effort app-foreground check via ActivityManager (no extra deps).
     * Returns false if the importance can't be determined.
     */
    @JvmStatic
    fun isAppForeground(): Boolean = runCatching {
        val info = android.app.ActivityManager.RunningAppProcessInfo()
        android.app.ActivityManager.getMyMemoryState(info)
        info.importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
            info.importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    }.getOrDefault(false)
}
