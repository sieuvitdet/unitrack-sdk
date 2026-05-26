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
     */
    @JvmStatic @JvmOverloads
    fun captureFcm(
        hasNotificationPayload: Boolean,
        isAppForeground: Boolean,
        title: String? = null,
        body: String? = null,
    ) {
        val state = when {
            !hasNotificationPayload -> "silent"
            isAppForeground         -> "foreground"
            else                    -> "background"
        }
        UniTrack.trackNotification(state, "received", title, body)
    }

    /** Log that the user opened/tapped a notification. */
    @JvmStatic @JvmOverloads
    fun captureOpened(title: String? = null, body: String? = null) {
        // An opened notification was, by definition, displayed to the user.
        val state = if (isAppForeground()) "foreground" else "background"
        UniTrack.trackNotification(state, "opened", title, body)
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
