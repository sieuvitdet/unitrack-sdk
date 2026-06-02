// SettingsViewController — camera settings + sharing.
// Covers: camera_ai_feature_toggled (#15) via UISwitch,
//         camera_shared (#20), camera_share_revoked (#21).

import UIKit
import UniTrack

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
            CameraAnalytics.aiFeatureToggled(cameraSerial: self.cameraId,
                                             aiFeatureCode: "person_detection", on: on)
        }
        let motionRow = makeSwitchRow(title: "AI phát hiện chuyển động", id: "ai_motion") { [weak self] on in
            guard let self else { return }
            CameraAnalytics.aiFeatureToggled(cameraSerial: self.cameraId,
                                             aiFeatureCode: "motion", on: on)
        }

        UI.fill(self, with: [
            aiRow,
            motionRow,
            UI.button("👥  Chia sẻ camera cho người khác", id: "camera_share") { [weak self] in
                guard let self else { return }
                CameraAnalytics.cameraShared(ownerId: "demo_user_42",
                                             cameraSerial: self.cameraId,
                                             sharerId: "friend_07")
            },
            UI.button("🚫  Thu hồi quyền chia sẻ", id: "camera_share_revoke") { [weak self] in
                guard let self else { return }
                CameraAnalytics.cameraShareRevoked(ownerId: "demo_user_42",
                                                   cameraSerial: self.cameraId,
                                                   sharerId: "friend_07")
            },
            UI.button("🔬  Test W3C Trace (sinh trace_id + gửi 1 HTTP call)", id: "test_w3c_trace") { [weak self] in
                self?.testW3CTrace()
            },
        ])
    }

    /// Demo button: mint a fresh W3C trace, log it loud, fire a one-shot
    /// HTTP call to the portal with the `traceparent` header attached so the
    /// resulting network_request event carries the same trace_id on the
    /// portal — operator can search the Events tab by this id to verify
    /// app-side and server-side logs join up.
    ///
    /// The URLProtocol that captures the request also reads the same
    /// trace_id (it auto-injects when tracing is enabled, but here we set
    /// the header explicitly so the demo works even with tracing.allowlist
    /// empty). The event still fires with the trace_id in its properties.
    private func testW3CTrace() {
        let trace = UniTrack.newTrace()
        let ts = ISO8601DateFormatter().string(from: Date())
        NSLog("""

        ─── 🔬 W3C Trace Context — Test Fire ───
          trace_id    %@
          span_id     %@
          traceparent %@
          fired_at    %@
          → Check portal Events tab, filter properties.trace_id=%@
        """, trace.traceId, trace.spanId, trace.header, ts, trace.traceId)

        // Fire a real HTTP request so the URLProtocol turns it into a
        // network_request event. Hit the portal's config endpoint with a
        // cache-busting query so we don't dedup with the periodic fetch.
        guard let url = URL(string: CameraAnalytics.configURL + "?trace_test=\(trace.traceId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer " + CameraAnalytics.apiKey, forHTTPHeaderField: "Authorization")
        req.setValue(trace.header, forHTTPHeaderField: "traceparent")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("[🔬 W3C] response status=%d err=%@", status, (err as NSError?)?.localizedDescription ?? "—")
        }.resume()

        // Toast on the device so the operator knows it worked without
        // having to switch to Xcode console.
        let alert = UIAlertController(
            title: "🔬 W3C Trace fired",
            message: "trace_id:\n\(trace.traceId)\n\nCheck portal Events tab, filter `trace_id` để verify.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Copy trace_id", style: .default) { _ in
            UIPasteboard.general.string = trace.traceId
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(alert, animated: true)
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
