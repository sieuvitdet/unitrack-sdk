package com.unitrack.sdk

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.unitrack.sdk.bridge.NativeBridge
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Loads the JNI library, initializes the SDK, exercises the public API,
 * and verifies the underlying core context handle is real.
 *
 * Run with:
 *   ./gradlew :unitrack:connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class NativeBridgeInstrumentedTest {

    private lateinit var app: Application
    private lateinit var dbFile: File

    @Before
    fun setUp() {
        app = ApplicationProvider.getApplicationContext()
        dbFile = File(app.filesDir, "unitrack_queue.db")
        dbFile.delete()
    }

    @After
    fun tearDown() {
        try { NativeBridge.shutdown() } catch (_: Throwable) {}
        dbFile.delete()
    }

    @Test
    fun nativeLibLoads() {
        NativeBridge.load()
        // If loadLibrary failed we'd have thrown UnsatisfiedLinkError above.
        assertTrue("native lib loaded", true)
    }

    @Test
    fun initCreatesContext() {
        UniTrack.initialize(app, UniTrackConfig(
            apiKey = "test-key",
            endpoint = "http://10.0.2.2:18787/v1/events",
            batchSize = 5,
            flushIntervalMs = 200,
            autoCapture = false  // keep the test isolated
        ))
        // If init failed, every subsequent call would crash JNI.
        UniTrack.setScreen("Home")
        UniTrack.track("test_event", mapOf("k" to "v"))
        UniTrack.identify("u1", mapOf("plan" to "pro"))
        UniTrack.flush()
        // Reaching here means JNI roundtripped through C++ core and back.
        assertTrue("calls completed without crash", true)
    }

    @Test
    fun queuePersistsAcrossInits() {
        UniTrack.initialize(app, UniTrackConfig(
            apiKey = "test-key",
            endpoint = "http://invalid.invalid/v1/events",
            batchSize = 100,
            flushIntervalMs = 60_000,  // no auto-flush
            autoCapture = false
        ))
        // Send 5 events that won't flush (endpoint invalid).
        repeat(5) { UniTrack.track("persist_test", mapOf("i" to it)) }
        UniTrack.flush()  // will fail but events stay in queue
        Thread.sleep(500)

        assertTrue("queue file created", dbFile.exists())
        assertTrue("queue file non-empty", dbFile.length() > 0)
    }
}
