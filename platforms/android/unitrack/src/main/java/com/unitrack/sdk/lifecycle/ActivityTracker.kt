package com.unitrack.sdk.lifecycle

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import com.unitrack.sdk.UniTrack

/**
 * Auto-tracks Activity and Fragment screen views.
 * No partner code required — just install once at SDK init.
 */
internal object ActivityTracker : Application.ActivityLifecycleCallbacks {

    /** Cửa sổ chờ (ms) trước khi chốt một màn là "màn thật". Activity/Fragment
     *  bị cái khác resume đè lên trong khoảng này là container trung gian
     *  (tab host, pager, nav wrapper) — chưa từng hiện cho người dùng thấy nên
     *  không bắn gì. Phân biệt bằng HÀNH VI thay vì blocklist tên class: SDK
     *  dùng chung cho nhiều app, không nên biết tên màn của app nào.
     *  Đổi qua portal `sdk_config.screen_settle_ms`. 0 = tắt lọc. */
    @JvmStatic
    var settleMs: Long = 50L

    /** Bộ đếm resume dùng CHUNG cho Activity lẫn Fragment — chúng đè lên nhau
     *  trong cùng một luồng dựng UI nên phải đếm chung mới lọc đúng.
     *  Chỉ chạm trên main thread (lifecycle callback + Handler main). */
    private var resumeSeq: Long = 0L
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** Hoãn `emit` qua cửa sổ settle; huỷ nếu có màn khác resume sau. */
    private fun afterSettle(emit: () -> Unit) {
        resumeSeq++
        val mySeq = resumeSeq
        if (settleMs <= 0L) { emit(); return }
        mainHandler.postDelayed({ if (resumeSeq == mySeq) emit() }, settleMs)
    }

    fun install(app: Application) {
        app.unregisterActivityLifecycleCallbacks(this) // idempotent
        app.registerActivityLifecycleCallbacks(this)
        // If an Activity is ALREADY resumed when we install (common when init
        // is async and finishes after the first onResume), no callback will
        // fire for it — emit setScreen for it now so the first screen isn't
        // lost, AND register fragment callbacks for it so subsequent fragment
        // transitions inside that activity are tracked.
        currentResumedActivity(app)?.let { a ->
            UniTrack.setScreen(resolveScreenName(a))
            if (a is FragmentActivity) {
                try {
                    a.supportFragmentManager.registerFragmentLifecycleCallbacks(fragmentCb, true)
                } catch (_: Throwable) { /* ignore */ }
            }
        }
    }

    @Suppress("PrivateApi", "DiscouragedPrivateApi")
    private fun currentResumedActivity(app: Application): Activity? = try {
        val tCls = Class.forName("android.app.ActivityThread")
        val tInstance = tCls.getMethod("currentActivityThread").invoke(null)
        val map = tCls.getDeclaredField("mActivities").apply { isAccessible = true }.get(tInstance) as Map<*, *>
        var found: Activity? = null
        for (record in map.values) {
            val rec = record ?: continue
            val pausedField = rec.javaClass.getDeclaredField("paused").apply { isAccessible = true }
            if (pausedField.getBoolean(rec)) continue
            val actField = rec.javaClass.getDeclaredField("activity").apply { isAccessible = true }
            found = actField.get(rec) as? Activity
            if (found != null) break
        }
        found
    } catch (_: Throwable) { null }

    // Stash wall-clock onCreate to measure load_ms at onResume (mirrors iOS
     // ViewControllerSwizzler viewDidLoad → viewDidAppear). Activity-based
     // screens cần load event đúng như Fragment để parity.
    private val activityCreatedAtMs = java.util.WeakHashMap<Activity, Long>()
    /** Mốc onStart gần nhất — trần cho load_ms. onResume lấy mốc MUỘN hơn
     *  giữa cái này và onCreate, nên Activity hiện lại (onCreate không chạy
     *  lại) hoặc nằm chờ giữa onStart→onResume đều không cộng quãng chờ. */
    private val activityStartedAtMs = java.util.WeakHashMap<Activity, Long>()

    override fun onActivityCreated(a: Activity, b: Bundle?) {
        activityCreatedAtMs[a] = android.os.SystemClock.elapsedRealtime()
    }

    override fun onActivityResumed(activity: Activity) {
        val name = resolveScreenName(activity)
        // load_ms chốt NGAY (thời điểm resume thật) nhưng chỉ gửi sau cửa sổ
        // settle — nếu đo trong callback sẽ cộng oan settleMs vào mọi màn.
        val anchor = maxOf(activityCreatedAtMs.remove(activity) ?: 0L,
                           activityStartedAtMs[activity] ?: 0L)
        val loadMs = if (anchor > 0L) {
            maxOf(0, (android.os.SystemClock.elapsedRealtime() - anchor).toInt())
        } else null

        afterSettle {
            // Capture previous screen BEFORE setScreen overwrites lastScreen so
            // screen_load_completed can stamp previous_screen_name.
            val prev = UniTrack.previousScreenName()
            // Dùng lại dup guard của setScreen: app dựng lại Activity/Fragment
            // cho CÙNG màn đang mở (vd tab bị setControllers lại khi API về)
            // không phải một lần vào màn mới — người dùng thấy một màn liên
            // tục, không có screen_end ở giữa. Lần dựng sau đo thời gian thay
            // view, không đo trải nghiệm của ai, nên bỏ.
            val sameScreen = UniTrack.setScreenReportingDup(name)

            // Fire screen_load_completed với create → resume delta. createdAt
            // đã remove() ở trên nên onPause/onStop/onResume cycle thứ 2 không
            // double-fire.
            if (loadMs != null && !sameScreen) {
                // is_cached heuristic: sub-100ms load = cache hit (view already
                // decoded, no cold render). Above the threshold = fresh render.
                val props = mutableMapOf<String, Any?>(
                    "screen"        to name,
                    "screen_name"   to name,
                    "load_time_ms"  to loadMs.toString(),
                    "is_cached"     to if (loadMs < 100) "true" else "false",
                )
                if (!prev.isNullOrEmpty()) props["previous_screen_name"] = prev
                UniTrack.track(UniTrack.screenLoadEventName, props)
            }
        }

        if (activity is FragmentActivity) {
            try {
                activity.supportFragmentManager.registerFragmentLifecycleCallbacks(
                    fragmentCb, true)
            } catch (_: Throwable) { /* ignore */ }
        }
    }

    override fun onActivityPaused(activity: Activity) {
        if (activity is FragmentActivity) {
            try {
                activity.supportFragmentManager.unregisterFragmentLifecycleCallbacks(
                    fragmentCb)
            } catch (_: Throwable) { /* ignore */ }
        }
    }

    /** Re-arm mốc load cho Activity hiện LẠI. onActivityCreated chỉ chạy một
     *  lần trong đời Activity, nên nếu không đặt lại mốc ở đây thì lần quay
     *  lại màn hoặc không có load_ms (mốc đã bị remove), hoặc cộng luôn quãng
     *  Activity nằm chờ. onStart là mốc tương đương iOS viewWillAppear.
     *  Lần đầu KHÔNG đụng: onActivityCreated vừa đặt mốc, ghi đè sẽ nuốt mất
     *  chính phần dựng view cần đo. */
    override fun onActivityStarted(a: Activity) {
        activityStartedAtMs[a] = android.os.SystemClock.elapsedRealtime()
    }
    override fun onActivityStopped(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
    override fun onActivityDestroyed(a: Activity) {
        activityCreatedAtMs.remove(a)
        activityStartedAtMs.remove(a)
    }

    private fun resolveScreenName(a: Activity): String {
        // Use the Activity's CLASS NAME as the stable screen name (mirrors the
        // iOS swizzler's ut_screenName). We intentionally do NOT use
        // activity.title — it's often a dynamic/display string (e.g. a camera
        // name or the app label) and not a stable analytics key.
        return a.javaClass.simpleName
    }

    // ─── Fragment tracking ────────────────────────────────────────────────
    // We stash the wall-clock at onFragmentCreated and measure load_ms at
    // onFragmentResumed (= "screen visible & interactive"). This mirrors iOS
    // ViewControllerSwizzler's viewDidLoad → viewDidAppear timing.
    private val createdAtMs = java.util.WeakHashMap<Fragment, Long>()
    /** Mốc onFragmentStarted gần nhất — trần cho load_ms.
     *  Xem ghi chú ở activityStartedAtMs. */
    private val startedAtMs = java.util.WeakHashMap<Fragment, Long>()

    private fun isNoiseFragmentName(name: String): Boolean =
        name.startsWith("Nav") || name == "ReportFragment" ||
        name == "ScreenStackFragment" || name == "ScreenFragment" ||
        name == "ScreenContainer" || name.startsWith("Supportable")

    private val fragmentCb = object : FragmentManager.FragmentLifecycleCallbacks() {
        override fun onFragmentCreated(fm: FragmentManager, f: Fragment, savedInstanceState: Bundle?) {
            if (isNoiseFragmentName(f.javaClass.simpleName)) return
            createdAtMs[f] = android.os.SystemClock.elapsedRealtime()
        }

        override fun onFragmentStarted(fm: FragmentManager, f: Fragment) {
            if (isNoiseFragmentName(f.javaClass.simpleName)) return
            startedAtMs[f] = android.os.SystemClock.elapsedRealtime()
        }

        override fun onFragmentResumed(fm: FragmentManager, f: Fragment) {
            val name = f.javaClass.simpleName
            if (isNoiseFragmentName(name)) return
            // load_ms chốt NGAY, gửi sau cửa sổ settle (xem afterSettle).
            // Cleared here so a re-entry (back-stack pop) gets a fresh load_ms
            // next time onFragmentCreated runs.
            val anchor = maxOf(createdAtMs.remove(f) ?: 0L, startedAtMs[f] ?: 0L)
            val loadMs = if (anchor > 0L) {
                maxOf(0, (android.os.SystemClock.elapsedRealtime() - anchor).toInt())
            } else null

            afterSettle {
                // Capture previous screen BEFORE setScreen overwrites lastScreen.
                val prev = UniTrack.previousScreenName()
                // Xem ghi chú dup guard ở nhánh Activity phía trên.
                val sameScreen = UniTrack.setScreenReportingDup(name)

                // Fire screen_load_completed with the create → resume delta. The
                // event name + auto-fire mirror the iOS swizzler so the wire shape
                // is the same on both platforms.
                if (loadMs != null && !sameScreen) {
                    val props = mutableMapOf<String, Any?>(
                        "screen"        to name,
                        "screen_name"   to name,
                        "load_time_ms"  to loadMs.toString(),
                        "is_cached"     to if (loadMs < 100) "true" else "false",
                    )
                    if (!prev.isNullOrEmpty()) props["previous_screen_name"] = prev
                    UniTrack.track(UniTrack.screenLoadEventName, props)
                }
            }
        }
    }
}
