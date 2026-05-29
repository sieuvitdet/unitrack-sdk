package com.unitrack.demo

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment

/**
 * B2B VMS/NVR flow. Covers vms_camera_connected/disconnected (#16,17),
 * vms_recording_played (#18), vms_alert_viewed (#19).
 */
class VmsFragment : Fragment() {

    private val nvrId = "nvr_hq_01"
    private var connectedChannel: Int? = null

    override fun onCreateView(i: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        val ctx = requireContext()
        return Ui.screen(ctx, listOf(
            Ui.header(ctx, "VMS (B2B)"),
            Ui.button(ctx, "🔌  Kết nối camera kênh 3", "vms_connect") {
                connectedChannel = 3
                CameraAnalytics.vmsCameraConnected(nvrId, 3)
            },
            Ui.button(ctx, "🔕  Ngắt kết nối", "vms_disconnect") {
                connectedChannel?.let {
                    CameraAnalytics.vmsCameraDisconnected(nvrId, it)
                    connectedChannel = null
                }
            },
            Ui.button(ctx, "⏯  Phát lại bản ghi NVR", "vms_playback") {
                CameraAnalytics.vmsRecordingPlayed(nvrId, 3, "nvr_rec_88")
            },
            Ui.button(ctx, "⚠️  Xem cảnh báo NVR", "vms_alert") {
                CameraAnalytics.vmsAlertViewed(nvrId, "line_crossing")
            },
        ))
    }
}
