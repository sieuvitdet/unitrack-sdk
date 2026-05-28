// LiveStreamViewController — B2C live stream + playback flow.
// Covers: camera_stream_started/ended/paused (#5,6,7),
//         camera_stream_first_frame / buffering (#27, #28),
//         camera_event_viewed (#8), camera_playback_started/ended (#9, #10).

import UIKit

final class LiveStreamViewController: UIViewController {
    private let cameraId: String
    private let cameraName: String
    private var streamStart: Date?


    init(cameraId: String, cameraName: String) {
        self.cameraId = cameraId
        self.cameraName = cameraName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = cameraName

        UI.fill(self, with: [
            UI.button("▶️  Bắt đầu xem trực tiếp", id: "stream_start") { [weak self] in
                self?.startStream()
            },
            UI.button("⏸  Tạm dừng", id: "stream_pause") { [weak self] in
                guard let self else { return }
                CameraAnalytics.streamPaused(cameraId: self.cameraId)
            },
            UI.button("⏹  Dừng xem", id: "stream_stop") { [weak self] in
                self?.stopStream()
            },
            UI.button("🎞  Xem sự kiện chuyển động", id: "event_view") { [weak self] in
                guard let self else { return }
                CameraAnalytics.eventViewed(cameraId: self.cameraId, eventType: "motion")
                DemoAPI.sequence([
                    ("/v1/cameras/\(self.cameraId)/events?type=motion", "GET", 200),
                    ("/v1/cameras/\(self.cameraId)/events/thumbnail",   "GET", 404),
                ])
            },
            UI.button("⏮  Phát lại bản ghi", id: "playback_start") { [weak self] in
                self?.playback()
            },
        ])
    }

    private func startStream() {
        streamStart = Date()
        CameraAnalytics.streamStarted(cameraId: cameraId, quality: "1080p")
        // Tapping "start stream" triggers a burst of backend calls — these get
        // auto-captured as network_request and nest under this tap in the tree.
        DemoAPI.sequence([
            ("/v1/cameras/\(cameraId)/stream/authorize", "POST", 200),
            ("/v1/cameras/\(cameraId)/stream/manifest",   "GET",  200),
            ("/v1/cameras/\(cameraId)/stream/keyframe",   "GET",  200),
            ("/v1/cameras/\(cameraId)/ai/motion-zones",   "GET",  200),
        ])
        // Simulate first-frame + a buffering blip with realistic timings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            CameraAnalytics.streamFirstFrame(cameraId: self.cameraId, ttfbMs: 600)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            CameraAnalytics.streamBuffering(cameraId: self.cameraId, durationMs: 350)
            // Buffering re-requests a fresh segment — sometimes the CDN 503s.
            DemoAPI.call("/v1/cameras/\(self.cameraId)/stream/segment-retry", method: "GET", status: 503)
        }
    }

    private func stopStream() {
        let ms = streamStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        CameraAnalytics.streamEnded(cameraId: cameraId, durationMs: ms)
        streamStart = nil
    }

    private func playback() {
        CameraAnalytics.playbackStarted(cameraId: cameraId, recordingId: "rec_20260525_1430")
        DemoAPI.sequence([
            ("/v1/recordings/rec_20260525_1430/manifest", "GET",  200),
            ("/v1/recordings/rec_20260525_1430/segments", "GET",  200),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            CameraAnalytics.playbackEnded(cameraId: self.cameraId, durationMs: 1500)
        }
    }

    // Leaving the screen while streaming = stream ended.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if streamStart != nil { stopStream() }
    }
}
