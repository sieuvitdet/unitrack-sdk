package com.unitrack.sdk

data class UniTrackConfig(
    val apiKey: String,
    val endpoint: String? = null,
    val batchSize: Int = 50,
    val flushIntervalMs: Int = 5000,
    val samplingRate: Double = 1.0,
    val autoCapture: Boolean = true,
    val trackScreens: Boolean = true,
    val trackTaps: Boolean = true,
    val trackNetwork: Boolean = true,
    val trackMemoryWarnings: Boolean = true,
    // Session journey tracking: emit session_start/session_end boundaries so the
    // portal can reconstruct each session's flow. sessionTimeoutMs is the
    // inactivity/background window after which a session is considered closed.
    val journeyCapture: Boolean = true,
    val sessionTimeoutMs: Int = 1_800_000,  // 30 min
    /**
     * Process khởi động KHÔNG do user mở app — FCM đánh thức để xử lý push,
     * WorkManager job, boot receiver. Session là "phiên sử dụng của user" nên
     * process không UI không được tạo session mới; nếu không mỗi push camera
     * lại đẻ một session sống vài giây, không screen, không user (đo được
     * session_index=1917 trên một máy prod).
     *
     * `null` (mặc định) = SDK tự phát hiện: không có Activity nào từng được
     * tạo tại thời điểm initialize() → headless. Đặt true/false để ép, dùng
     * khi host biết rõ hơn SDK.
     */
    val headlessLaunch: Boolean? = null,
    // Screen lifecycle: on screen change, core also emits screen_end (with
    // dwell_ms) for the screen being left and screen_start for the new one.
    // Both event names are renameable so a team can map them onto its own
    // taxonomy (e.g. "page_enter" / "page_leave") via remote config.
    val screenLifecycle: Boolean = true,
    val screenStartEvent: String = "screen_start",
    val screenEndEvent: String = "screen_end",
    /** Event name fired by ActivityTracker's fragment lifecycle hook with
     *  load_ms (the onFragmentCreated → onFragmentResumed window). Mirrors
     *  the iOS swizzler's `screen_load_completed`. Renameable via portal
     *  `sdk_config.screen_load_event`. */
    val screenLoadEvent: String = "screen_load_completed",
)
