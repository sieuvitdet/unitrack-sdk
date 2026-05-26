// SettingsViewController — camera settings + sharing.
// Covers: camera_ai_feature_toggled (#15) via UISwitch,
//         camera_shared (#20), camera_share_revoked (#21).

import UIKit

final class SettingsViewController: UIViewController {

    private let cameraId = "cam_living_room"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Cài đặt"

        // AI feature toggle (UISwitch also auto-emits a `tap`; the switch's
        // value-changed handler emits the semantic camera_ai_feature_toggled).
        let aiRow = makeSwitchRow(title: "AI nhận diện người", id: "ai_person_detection") { [weak self] on in
            guard let self else { return }
            CameraAnalytics.aiFeatureToggled(cameraId: self.cameraId, feature: "person_detection", enabled: on)
        }
        let motionRow = makeSwitchRow(title: "AI phát hiện chuyển động", id: "ai_motion") { [weak self] on in
            guard let self else { return }
            CameraAnalytics.aiFeatureToggled(cameraId: self.cameraId, feature: "motion", enabled: on)
        }

        UI.fill(self, with: [
            aiRow,
            motionRow,
            UI.button("👥  Chia sẻ camera cho người khác", id: "camera_share") { [weak self] in
                guard let self else { return }
                CameraAnalytics.cameraShared(cameraId: self.cameraId, withUser: "friend_07")
            },
            UI.button("🚫  Thu hồi quyền chia sẻ", id: "camera_share_revoke") { [weak self] in
                guard let self else { return }
                CameraAnalytics.cameraShareRevoked(cameraId: self.cameraId, fromUser: "friend_07")
            },
        ])
    }

    private func makeSwitchRow(title: String, id: String,
                               _ onChange: @escaping (Bool) -> Void) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 16)
        let sw = UISwitch()
        sw.accessibilityIdentifier = id
        sw.addAction(UIAction { _ in onChange(sw.isOn) }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [label, sw])
        row.axis = .horizontal
        row.distribution = .equalSpacing
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.backgroundColor = .secondarySystemBackground
        row.layer.cornerRadius = 10
        return row
    }
}
