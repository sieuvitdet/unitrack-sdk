package com.unitrack.demo

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import com.unitrack.sdk.UniTrack

/**
 * Camera settings + sharing + user identity.
 * Covers camera_ai_feature_toggled (#15) via Switch, camera_shared (#20),
 * camera_share_revoked (#21), and identify / reset.
 */
class SettingsFragment : Fragment() {

    private val cameraId = "cam_living_room"

    companion object {
        // Two demo users so per-user filtering/journeys can be shown in the portal.
        private val DEMO_USERS = listOf(
            "demo_user_42" to "b2c_premium",
            "demo_user_07" to "b2c_basic",
        )
        private var loginIdx = 0
    }

    override fun onCreateView(i: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        val ctx = requireContext()
        return Ui.screen(ctx, listOf(
            Ui.header(ctx, "Cài đặt"),
            Ui.switchRow(ctx, "AI nhận diện người", "ai_person_detection") { on ->
                CameraAnalytics.aiFeatureToggled(cameraId, "person_detection", on)
            },
            Ui.switchRow(ctx, "AI phát hiện chuyển động", "ai_motion") { on ->
                CameraAnalytics.aiFeatureToggled(cameraId, "motion", on)
            },
            Ui.button(ctx, "👥  Chia sẻ camera", "camera_share") {
                CameraAnalytics.cameraShared(cameraId, "friend_07")
            },
            Ui.button(ctx, "🚫  Thu hồi chia sẻ", "camera_share_revoke") {
                CameraAnalytics.cameraShareRevoked(cameraId, "friend_07")
            },
            Ui.button(ctx, "🔑  Đăng nhập (identify)", "login") {
                // Alternate between two demo users so the portal shows per-user
                // filtering / journeys. Each tap logs in the "next" user.
                val u = DEMO_USERS[loginIdx % DEMO_USERS.size]
                loginIdx++
                UniTrack.identify(u.first, mapOf("plan" to u.second, "region" to "VN"))
            },
            Ui.button(ctx, "🚪  Đăng xuất (reset)", "logout") {
                UniTrack.reset()
            },
        ))
    }
}
