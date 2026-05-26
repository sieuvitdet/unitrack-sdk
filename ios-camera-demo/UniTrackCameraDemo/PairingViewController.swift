// PairingViewController — camera onboarding / pairing flow.
// Covers: camera_pairing_started (#22), camera_pairing_completed (#23),
//         camera_pairing_failed (#24), camera_registered (#25).

import UIKit

final class PairingViewController: UIViewController {

    private var pairStart: Date?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Thêm Camera"
        UI.fill(self, with: [
            UI.button("📡  Bắt đầu ghép nối (QR)", id: "pairing_start") { [weak self] in
                self?.pairStart = Date()
                CameraAnalytics.pairingStarted(method: "qr_code")
            },
            UI.button("✅  Ghép nối thành công", id: "pairing_success") { [weak self] in
                guard let self else { return }
                let ms = self.pairStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
                CameraAnalytics.pairingCompleted(cameraId: "cam_new_99", durationMs: ms)
                CameraAnalytics.cameraRegistered(cameraId: "cam_new_99", model: "MobiCam Pro 2K")
            },
            UI.button("❌  Ghép nối thất bại", id: "pairing_fail") {
                CameraAnalytics.pairingFailed(reason: "wifi_timeout", code: "E_TIMEOUT")
            },
        ])
    }
}
