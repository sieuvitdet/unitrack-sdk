package com.unitrack.demo

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.fragment.app.Fragment
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.UniTrackJson
import com.unitrack.sdk.UniTrackNotifications

/**
 * Alerts + notification lifecycle + the misc capture helpers.
 * Covers notification_permission_checked (#11), camera_notification_sent/
 * delivered/clicked (#12,13,14), application_error (#30), a real crash,
 * json_parse_error, and the semantic helpers trackNotification / trackDeeplink /
 * trackWebViewOpen / trackThirdPartyOpen.
 */
class AlertsFragment : Fragment() {

    override fun onCreateView(i: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        val ctx = requireContext()
        return Ui.screen(ctx, listOf(
            Ui.header(ctx, "Cảnh báo & sự kiện hệ thống"),

            Ui.button(ctx, "🔔  Mô phỏng cảnh báo chuyển động", "notif_motion_alert") {
                CameraAnalytics.notificationSent("cam_front_door", "motion")
                // The SDK notification helper: a received push (foreground).
                UniTrackNotifications.captureFcm(
                    hasNotificationPayload = true,
                    isAppForeground = true,
                    title = "Phát hiện chuyển động",
                    body = "Camera Cửa trước phát hiện chuyển động",
                )
                CameraAnalytics.notificationDelivered("cam_front_door", "motion")
            },
            Ui.button(ctx, "👆  Mô phỏng bấm vào thông báo", "notif_clicked") {
                UniTrackNotifications.captureOpened("Phát hiện chuyển động", "Camera Cửa trước")
                CameraAnalytics.notificationClicked("cam_front_door", "motion")
            },
            Ui.button(ctx, "🔐  Kiểm tra quyền thông báo", "notif_permission") {
                // (Demo: report as granted; a real app reads NotificationManager.)
                CameraAnalytics.notificationPermissionChecked(granted = true)
            },

            // Open a deeplink INTO the MobiX app. Android routes the mobix://
            // URI to whichever app registered that scheme (the real MobiX app).
            // The event you want to verify shows up on the MobiX project in the
            // portal — emitted by UniTrack running inside MobiX when it handles
            // the deeplink — NOT on this demo project. (We also trackDeeplink
            // here so the demo's own session shows the outgoing open.)
            Ui.button(ctx, "🔗  Mở MobiX qua deeplink", "open_mobix_deeplink") {
                val uri = "mobix://open?screen=detail&id=123"
                UniTrack.trackDeeplink(uri, source = "camera_demo")
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    })
                } catch (e: ActivityNotFoundException) {
                    Toast.makeText(ctx, "Chưa cài app MobiX (không có app nào nhận mobix://)", Toast.LENGTH_LONG).show()
                }
            },
            Ui.button(ctx, "🌐  Mở WebView", "open_webview") {
                UniTrack.trackWebViewOpen("https://mobix.asia/help/cameras")
            },
            Ui.button(ctx, "📤  Mở app bên thứ ba", "open_thirdparty") {
                UniTrack.trackThirdPartyOpen("zalo")
            },

            Ui.button(ctx, "💥  Báo lỗi xử lý (non-fatal)", "report_error") {
                CameraAnalytics.applicationError("StreamDecoder", "Failed to decode H.265 frame")
            },
            Ui.button(ctx, "🧩  Parse JSON lỗi (json_parse_error)", "bad_json") {
                UniTrackJson.parse("CameraDto", "{ this is : not valid json ]")
            },
            Ui.button(ctx, "🧨  Gây crash thật (test crash)", "force_crash") {
                // Real uncaught exception → captured by DemoApp's crash handler.
                val arr = IntArray(0)
                @Suppress("UNUSED_VARIABLE") val x = arr[99]
            },
        ))
    }
}
