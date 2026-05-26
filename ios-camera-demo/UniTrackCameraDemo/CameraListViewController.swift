// CameraListViewController — B2C camera list. Selecting an item opens the live
// stream screen. Covers: camera_item_selected (#29), and pushes the stream flow.
// screen_view + screen_load_completed fire automatically (SDK swizzle).

import UIKit

final class CameraListViewController: UIViewController {

    private let cameras = [
        ("cam_living_room", "Phòng khách"),
        ("cam_front_door",  "Cửa trước"),
        ("cam_garage",      "Nhà xe"),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Cameras"

        var buttons: [UIView] = []
        for (i, cam) in cameras.enumerated() {
            buttons.append(UI.button("📹  \(cam.1)", id: "camera_item_\(cam.0)") { [weak self] in
                CameraAnalytics.cameraItemSelected(cameraId: cam.0, position: i)
                self?.openStream(cameraId: cam.0, name: cam.1)
            })
        }
        // A real API call so network_request auto-capture has something to catch.
        buttons.append(UI.button("🔄  Tải danh sách (API)", id: "camera_list_refresh") {
            URLSession.shared.dataTask(with: URL(string: "https://httpbin.org/get")!).resume()
        })
        UI.fill(self, with: buttons)
    }

    private func openStream(cameraId: String, name: String) {
        navigationController?.pushViewController(
            LiveStreamViewController(cameraId: cameraId, cameraName: name), animated: true)
    }
}
