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
)
