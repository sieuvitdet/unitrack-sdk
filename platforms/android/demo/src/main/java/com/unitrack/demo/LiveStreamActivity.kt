package com.unitrack.demo

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.appcompat.app.AppCompatActivity

/**
 * B2C live-stream + playback flow (own screen → screen_view "LiveStreamActivity").
 * Covers camera_stream_started/ended/paused (#5,6,7), stream_first_frame /
 * buffering (#27,28), camera_event_viewed (#8), playback_started/ended (#9,10).
 * Each action fires a burst of API calls so the session wireframe nests
 * network_request under the triggering tap.
 */
class LiveStreamActivity : AppCompatActivity() {

    private lateinit var cameraId: String
    private var streamStart: Long = 0L
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        cameraId = intent.getStringExtra("camera_id") ?: "cam_unknown"
        title = intent.getStringExtra("camera_name") ?: "Live stream"

        setContentView(Ui.screen(this, listOf(
            Ui.header(this, title.toString()),
            Ui.button(this, "▶️  Bắt đầu xem trực tiếp", "stream_start") { startStream() },
            Ui.button(this, "⏸  Tạm dừng", "stream_pause") { CameraAnalytics.streamPaused(cameraId) },
            Ui.button(this, "⏹  Dừng xem", "stream_stop") { stopStream() },
            Ui.button(this, "🎞  Xem sự kiện chuyển động", "event_view") {
                CameraAnalytics.eventViewed(cameraId, "motion")
                DemoApi.sequence(listOf(
                    Triple("/v1/cameras/$cameraId/events?type=motion", "GET", 200),
                    Triple("/v1/cameras/$cameraId/events/thumbnail", "GET", 404),
                ))
            },
            Ui.button(this, "⏮  Phát lại bản ghi", "playback_start") { playback() },
        )))
    }

    private fun startStream() {
        streamStart = System.currentTimeMillis()
        CameraAnalytics.streamStarted(cameraId, "1080p")
        DemoApi.sequence(listOf(
            Triple("/v1/cameras/$cameraId/stream/authorize", "POST", 200),
            Triple("/v1/cameras/$cameraId/stream/manifest", "GET", 200),
            Triple("/v1/cameras/$cameraId/stream/keyframe", "GET", 200),
            Triple("/v1/cameras/$cameraId/ai/motion-zones", "GET", 200),
        ))
        main.postDelayed({ CameraAnalytics.streamFirstFrame(cameraId, 600) }, 600)
        main.postDelayed({
            CameraAnalytics.streamBuffering(cameraId, 350)
            DemoApi.call("/v1/cameras/$cameraId/stream/segment-retry", "GET", 503)
        }, 2000)
    }

    private fun stopStream() {
        if (streamStart == 0L) return
        CameraAnalytics.streamEnded(cameraId, (System.currentTimeMillis() - streamStart).toInt())
        streamStart = 0L
    }

    private fun playback() {
        CameraAnalytics.playbackStarted(cameraId, "rec_20260525_1430")
        DemoApi.sequence(listOf(
            Triple("/v1/recordings/rec_20260525_1430/manifest", "GET", 200),
            Triple("/v1/recordings/rec_20260525_1430/segments", "GET", 200),
        ))
        main.postDelayed({ CameraAnalytics.playbackEnded(cameraId, 1500) }, 1500)
    }

    override fun onPause() {
        super.onPause()
        if (isFinishing) stopStream()   // leaving while streaming = stream ended
    }
}
