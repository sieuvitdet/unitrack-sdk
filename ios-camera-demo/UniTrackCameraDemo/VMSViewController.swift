// VMSViewController — B2B VMS/NVR flow.
// Covers: vms_camera_connected/disconnected (#16, #17),
//         vms_recording_played (#18), vms_alert_viewed (#19).

import UIKit

final class VMSViewController: UIViewController {

    private let nvrId = "nvr_hq_01"
    private var connectedChannel: Int?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "VMS (B2B)"
        UI.fill(self, with: [
            UI.button("🔌  Kết nối camera kênh 3", id: "vms_connect") { [weak self] in
                guard let self else { return }
                self.connectedChannel = 3
                CameraAnalytics.vmsCameraConnected(nvrId: self.nvrId, channel: 3)
            },
            UI.button("🔕  Ngắt kết nối", id: "vms_disconnect") { [weak self] in
                guard let self, let ch = self.connectedChannel else { return }
                CameraAnalytics.vmsCameraDisconnected(nvrId: self.nvrId, channel: ch)
                self.connectedChannel = nil
            },
            UI.button("⏯  Phát lại bản ghi NVR", id: "vms_playback") { [weak self] in
                guard let self else { return }
                CameraAnalytics.vmsRecordingPlayed(nvrId: self.nvrId, channel: 3,
                                                   recordingId: "nvr_rec_88")
            },
            UI.button("⚠️  Xem cảnh báo NVR", id: "vms_alert") { [weak self] in
                guard let self else { return }
                CameraAnalytics.vmsAlertViewed(nvrId: self.nvrId, alertType: "line_crossing")
            },
        ])
    }
}
