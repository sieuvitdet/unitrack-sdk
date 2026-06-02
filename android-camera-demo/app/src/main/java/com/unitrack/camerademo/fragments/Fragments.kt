// Fragments.kt — all 5 demo fragments in one file. Each one mirrors the
// equivalent iOS view controller and exists for the SDK's auto-capture to
// have realistic screen_viewed / tap events to consume.
//
// Buttons set android:tag = "<element_key>" because the SDK's ClickTracker
// reads view.tag in preference to text — analogous to iOS
// accessibilityIdentifier. That way the portal rule rewrites still match
// even after the visible label is translated.

package com.unitrack.camerademo.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.unitrack.camerademo.CameraAnalytics
import com.unitrack.sdk.UniTrack

// ── Helpers ─────────────────────────────────────────────────────────────────
// Build a vertical stack of buttons quickly. Each button auto-fires the lambda
// on tap AND the SDK auto-tracks the tap with element_key = view.tag.

private fun Fragment.column(title: String, vararg rows: View): View {
    val ctx = requireContext()
    val ll = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(48, 48, 48, 48)
    }
    ll.addView(TextView(ctx).apply {
        text = title
        textSize = 22f
        setPadding(0, 0, 0, 24)
    })
    for (r in rows) {
        (r.layoutParams as? LinearLayout.LayoutParams)
            ?: LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(0, 12, 0, 12) }
            .also { r.layoutParams = it }
        ll.addView(r)
    }
    return ll
}

private fun Fragment.btn(label: String, id: String, onTap: () -> Unit): View {
    return Button(requireContext()).apply {
        text = label
        tag  = id   // ClickTracker uses this as element_key
        setOnClickListener { onTap() }
    }
}

// ── Tab 1: Camera list (B2C) ────────────────────────────────────────────────
class CameraListFragment : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?,
                              savedInstanceState: Bundle?): View {
        val cameras = listOf(
            "cam_living_room" to "Living Room",
            "cam_front_door"  to "Front Door",
            "cam_garage"      to "Garage",
        )
        return column("Cameras",
            *cameras.map { (serial, name) ->
                btn("📹 $name", "camera_item_$serial") {
                    CameraAnalytics.cameraItemSelected(serial, "CameraListFragment")
                    parentFragmentManager.beginTransaction()
                        .replace((requireView().parent as View).id, LiveStreamFragment.create(serial))
                        .addToBackStack(null)
                        .commit()
                }
            }.toTypedArray(),
            btn("🔄  Refresh list", "camera_list_refresh") {
                // No-op — the tap itself is the tracked event.
            },
        )
    }
}

// ── LiveStream sub-screen (pushed from camera list) ────────────────────────
class LiveStreamFragment : Fragment() {
    private val cameraId by lazy { requireArguments().getString("camera") ?: "cam_unknown" }
    private var startMs = 0L

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?,
                              savedInstanceState: Bundle?): View {
        return column("Live: $cameraId",
            btn("▶︎  Start", "stream_start") {
                startMs = System.currentTimeMillis()
                CameraAnalytics.streamStarted(cameraId, 1, "single", 1)
                // First-frame ~600ms after start (simulated).
                requireView().postDelayed({
                    CameraAnalytics.streamFirstFrame(cameraId, 600, "live")
                }, 600)
            },
            btn("⏸  Pause", "stream_pause") {
                CameraAnalytics.streamPaused(cameraId)
            },
            btn("🎞  View event recording", "event_view") {
                CameraAnalytics.eventViewed(cameraId)
            },
            btn("⏯  Start playback", "playback_start") {
                CameraAnalytics.playbackStarted(cameraId)
                requireView().postDelayed({
                    CameraAnalytics.playbackEnded(cameraId, 1)
                }, 800)
            },
            btn("⏹  Stop", "stream_stop") {
                val sec = ((System.currentTimeMillis() - startMs) / 1000).toInt().coerceAtLeast(1)
                CameraAnalytics.streamEnded(cameraId, sec, "single")
            },
        )
    }
    companion object {
        fun create(serial: String) = LiveStreamFragment().apply {
            arguments = Bundle().apply { putString("camera", serial) }
        }
    }
}

// ── Tab 2: VMS (B2B) ────────────────────────────────────────────────────────
class VMSFragment : Fragment() {
    private val nvr = "nvr_hq_01_ch3"
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?,
                              savedInstanceState: Bundle?): View {
        return column("VMS — $nvr",
            btn("🔌  Connect", "vms_connect") {
                CameraAnalytics.vmsCameraConnected(nvr, 4, "grid")
            },
            btn("📼  Play recording", "vms_playback") {
                CameraAnalytics.vmsRecordingPlayed(nvr, 30)
            },
            btn("🚨  View alert", "vms_alert") {
                CameraAnalytics.vmsAlertViewed(nvr, "line_crossing")
            },
            btn("🔚  Disconnect", "vms_disconnect") {
                CameraAnalytics.vmsCameraDisconnected(nvr, 60)
            },
        )
    }
}

// ── Tab 3: Pairing ──────────────────────────────────────────────────────────
class PairingFragment : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?,
                              savedInstanceState: Bundle?): View {
        return column("Add a camera",
            btn("🆕  Start pairing", "pairing_start") {
                CameraAnalytics.pairingStarted()
            },
            btn("✅  Complete (mock)", "pairing_success") {
                CameraAnalytics.pairingCompleted("cam_new_99")
                CameraAnalytics.cameraRegistered("cam_new_99", "FPT-Cam V2")
            },
            btn("❌  Fail (mock)", "pairing_fail") {
                CameraAnalytics.pairingFailed("E_TIMEOUT")
            },
        )
    }
}

// ── Tab 4: Alerts / Notifications ───────────────────────────────────────────
class AlertsFragment : Fragment() {
    private val cam = "cam_front_door"
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?,
                              savedInstanceState: Bundle?): View {
        return column("Alerts & notifications",
            btn("🔔  Ask notification permission", "notif_request_permission") {
                CameraAnalytics.notificationPermissionChecked(true)
            },
            btn("📨  Simulate motion notification", "notif_motion_alert") {
                CameraAnalytics.notificationSent(cam, "motion")
                requireView().postDelayed({
                    CameraAnalytics.notificationDelivered(cam, "motion")
                }, 300)
            },
            btn("👆  User clicked notification", "notif_clicked") {
                CameraAnalytics.notificationClicked(cam, "Motion at Front Door")
            },
            btn("🔗  Open MobiX via deeplink", "open_mobix_deeplink") {
                val url = "mobix://open?screen=detail&id=123"
                UniTrack.trackDeeplink(url, "camera_demo")
                runCatching {
                    startActivity(android.content.Intent(
                        android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)))
                }
            },
            btn("💥  Report error (non-fatal)", "report_error") {
                CameraAnalytics.applicationError("StreamDecoderError",
                    "Failed to decode H.265 frame", isFatal = false)
            },
            btn("🧨  Force real crash (test #30)", "force_crash") {
                // Real crash. SDK's signal handler writes crash-pending.json,
                // recovered on next launch and POSTed as `crash`. App code
                // does NOTHING here — automatic capture is the whole point.
                val arr: List<Int> = emptyList()
                arr[99]
            },
        )
    }
}

// ── Tab 5: Settings (AI toggles + share) ────────────────────────────────────
class SettingsFragment : Fragment() {
    private val cam = "cam_living_room"
    private val friend = "friend_07"

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?,
                              savedInstanceState: Bundle?): View {
        val ctx = requireContext()
        val sw1 = Switch(ctx).apply {
            text = "Person detection"
            tag = "ai_person_detection"
            setOnCheckedChangeListener { _, on ->
                CameraAnalytics.aiFeatureToggled(cam, "person_detection", on)
            }
        }
        val sw2 = Switch(ctx).apply {
            text = "Motion alerts"
            tag = "ai_motion"
            setOnCheckedChangeListener { _, on ->
                CameraAnalytics.aiFeatureToggled(cam, "motion", on)
            }
        }
        return column("Settings",
            sw1, sw2,
            btn("🔗  Share with friend_07", "camera_share") {
                CameraAnalytics.cameraShared(cam, friend)
            },
            btn("🚫  Revoke share", "camera_share_revoke") {
                CameraAnalytics.cameraShareRevoked(cam, friend)
            },
            btn("🚀  Fire ALL events (smoke test)", "smoke_fire_all") {
                CameraAnalytics.fireAllForSmokeTest()
            },
        )
    }
}
