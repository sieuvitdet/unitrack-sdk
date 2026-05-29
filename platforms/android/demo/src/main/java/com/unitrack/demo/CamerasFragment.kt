package com.unitrack.demo

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment

/**
 * B2C camera list. Selecting an item opens the live-stream screen.
 * Covers camera_item_selected (#29) + a real API call (network_request).
 * screen_view fires automatically (Fragment name = "CamerasFragment").
 */
class CamerasFragment : Fragment() {

    private val cameras = listOf(
        "cam_living_room" to "Phòng khách",
        "cam_front_door" to "Cửa trước",
        "cam_garage" to "Nhà xe",
    )

    override fun onCreateView(i: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        val ctx = requireContext()
        val views = mutableListOf<View>(Ui.header(ctx, "Cameras (B2C)"))
        cameras.forEachIndexed { idx, (id, name) ->
            views += Ui.button(ctx, "📹  $name", "camera_item_$id") {
                CameraAnalytics.cameraItemSelected(id, idx)
                startActivity(Intent(ctx, LiveStreamActivity::class.java).apply {
                    putExtra("camera_id", id)
                    putExtra("camera_name", name)
                })
            }
        }
        views += Ui.button(ctx, "🔄  Tải danh sách (API)", "camera_list_refresh") {
            DemoApi.call("/v1/cameras", "GET", 200)
        }
        return Ui.screen(ctx, views)
    }
}
