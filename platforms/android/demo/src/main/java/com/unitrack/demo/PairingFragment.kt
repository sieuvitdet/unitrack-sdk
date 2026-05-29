package com.unitrack.demo

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment

/**
 * Camera onboarding / pairing flow. Covers camera_pairing_started (#22),
 * camera_pairing_completed (#23), camera_pairing_failed (#24),
 * camera_registered (#25).
 */
class PairingFragment : Fragment() {

    private var pairStart: Long = 0L

    override fun onCreateView(i: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        val ctx = requireContext()
        return Ui.screen(ctx, listOf(
            Ui.header(ctx, "Thêm Camera"),
            Ui.button(ctx, "📡  Bắt đầu ghép nối (QR)", "pairing_start") {
                pairStart = System.currentTimeMillis()
                CameraAnalytics.pairingStarted("qr_code")
            },
            Ui.button(ctx, "✅  Ghép nối thành công", "pairing_success") {
                val ms = if (pairStart > 0) (System.currentTimeMillis() - pairStart).toInt() else 0
                CameraAnalytics.pairingCompleted("cam_new_99", ms)
                CameraAnalytics.cameraRegistered("cam_new_99", "MobiCam Pro 2K")
            },
            Ui.button(ctx, "❌  Ghép nối thất bại", "pairing_fail") {
                CameraAnalytics.pairingFailed("wifi_timeout", "E_TIMEOUT")
            },
        ))
    }
}
