// NotificationsViewController — alerts + notification lifecycle + errors.
// Covers: notification_permission_checked (#11), camera_notification_sent (#12),
//         camera_notification_delivered (#13), camera_notification_clicked (#14),
//         application_error (#30). Real local notifications also exercise the
//         UniTrackNotifications.wrap() auto-capture (received/opened).

import UIKit
import UserNotifications
import UniTrack

final class NotificationsViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Cảnh báo"
        UI.fill(self, with: [
            UI.button("🔐  Xin & kiểm tra quyền thông báo", id: "notif_request_permission") { [weak self] in
                self?.requestPermission()
            },
            UI.button("🔔  Mô phỏng cảnh báo chuyển động", id: "notif_motion_alert") { [weak self] in
                self?.fireMotionAlert()
            },
            UI.button("👆  Mô phỏng bấm vào thông báo", id: "notif_clicked") {
                CameraAnalytics.notificationClicked(cameraId: "cam_front_door", type: "motion")
            },
            // Open the MobiX app via its custom-scheme deeplink. iOS routes
            // mobix:// to whichever installed app registered that scheme (the
            // real MobiX app). The deeplink_opened event then shows up on the
            // MobiX project in the portal — emitted by UniTrack inside MobiX.
            UI.button("🔗  Mở MobiX qua deeplink", id: "open_mobix_deeplink") {
                let urlStr = "mobix://open?screen=detail&id=123"
                UniTrack.trackDeeplink(urlStr, source: "camera_demo")
                if let url = URL(string: urlStr) {
                    UIApplication.shared.open(url, options: [:]) { ok in
                        if !ok { CameraAnalytics.applicationError(
                            domain: "Deeplink",
                            message: "Không mở được \(urlStr) — chưa cài MobiX?") }
                    }
                }
            },
            UI.button("💥  Báo lỗi xử lý (non-fatal)", id: "report_error") {
                CameraAnalytics.applicationError(domain: "StreamDecoder",
                                                 message: "Failed to decode H.265 frame")
            },
            UI.button("🧨  Gây crash thật (test #30)", id: "force_crash") {
                // A real crash → auto-captured as `crash` on next launch.
                let arr: [Int] = []
                _ = arr[99]
            },
        ])
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            CameraAnalytics.notificationPermissionChecked(granted: granted)
        }
    }

    // Sent → delivered (via OS) → the wrap() helper records received/opened.
    private func fireMotionAlert() {
        let cameraId = "cam_front_door"
        CameraAnalytics.notificationSent(cameraId: cameraId, type: "motion")

        let content = UNMutableNotificationContent()
        content.title = "Phát hiện chuyển động"
        content.body  = "Camera Cửa trước phát hiện chuyển động"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(req) { error in
            if error == nil {
                CameraAnalytics.notificationDelivered(cameraId: cameraId, type: "motion")
            }
        }
    }
}
