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
)
