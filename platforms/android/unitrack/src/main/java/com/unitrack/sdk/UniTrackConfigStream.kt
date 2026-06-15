package com.unitrack.sdk

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/**
 * SSE (Server-Sent Events) client for realtime portal config updates.
 *
 * Mirrors UniTrackConfigStream.swift — host opens a long-lived HTTP
 * connection to {BASE}/config/stream and the portal pushes a
 * `config_changed` event each time a save lands. The SDK fires the
 * supplied callback so the host can re-fetch + re-apply.
 *
 *     UniTrackConfigStream.start(
 *         apiKey   = "utk_...",
 *         streamUrl = "https://mobix.asia/.../config/stream",
 *         flavor   = "beta",
 *     ) {
 *         // re-fetch UniTrackRemoteConfig + re-apply
 *     }
 *
 *     UniTrackConfigStream.stop()   // logout / app teardown
 *
 * Behaviour matches iOS:
 *   • Auto-reconnect with exponential backoff (1s → 2s → … → 30s)
 *   • Pauses on background, resumes on foreground (wired via
 *     UniTrack.addLifecycleListener)
 *   • Ignores SSE comment lines (`: ping` heartbeat)
 *   • Coalesces 500ms bursts to one callback
 *
 * Uses HttpURLConnection rather than OkHttp so the SDK has zero hard
 * dependency on a third-party HTTP client.
 */
object UniTrackConfigStream {

    private const val TAG = "UniTrackConfigStream"
    private const val MAX_BACKOFF_MS = 30_000L
    private const val COALESCE_MS = 500L

    private var apiKey: String = ""
    private var streamUrl: String = ""
    private var flavor: String? = null
    @Volatile private var onConfigChanged: (() -> Unit)? = null

    private val running = AtomicBoolean(false)
    private var workerThread: Thread? = null
    private var currentConnection: HttpURLConnection? = null
    @Volatile private var backoffMs: Long = 1_000L

    // Coalesce timer state — one pending callback at a time.
    @Volatile private var pendingCallback = false
    private val coalesceLock = Any()

    /**
     * Start the SSE connection. Idempotent — calling again with the same args
     * keeps the existing connection; with different args closes + reopens.
     */
    @JvmStatic
    @JvmOverloads
    fun start(apiKey: String,
              streamUrl: String,
              flavor: String? = null,
              onConfigChanged: () -> Unit) {
        if (running.get()
            && this.apiKey == apiKey
            && this.streamUrl == streamUrl
            && this.flavor == flavor) {
            this.onConfigChanged = onConfigChanged
            return
        }
        stop()
        this.apiKey = apiKey
        this.streamUrl = streamUrl
        this.flavor = flavor
        this.onConfigChanged = onConfigChanged
        running.set(true)
        installLifecycle()
        spawnWorker()
    }

    /** Tear down the stream — call from logout / app teardown. */
    @JvmStatic
    fun stop() {
        running.set(false)
        try { currentConnection?.disconnect() } catch (_: Throwable) {}
        currentConnection = null
        workerThread?.interrupt()
        workerThread = null
        backoffMs = 1_000L
    }

    // ─── connection loop ──────────────────────────────────────────────────

    private fun spawnWorker() {
        if (workerThread?.isAlive == true) return
        val t = Thread({
            while (running.get()) {
                try { runOnce() } catch (e: Throwable) {
                    Log.w(TAG, "stream error: ${e.message}")
                }
                if (!running.get()) break
                val sleep = backoffMs
                backoffMs = (backoffMs * 2).coerceAtMost(MAX_BACKOFF_MS)
                try { Thread.sleep(sleep) } catch (_: InterruptedException) { break }
            }
        }, "UniTrack-SSE")
        t.isDaemon = true
        workerThread = t
        t.start()
    }

    private fun runOnce() {
        val url = URL(buildUrl())
        val conn = (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout    = 0        // 0 = wait forever, SSE streams indefinitely
            setRequestProperty("Authorization",     "Bearer $apiKey")
            setRequestProperty("Accept",            "text/event-stream")
            setRequestProperty("Cache-Control",     "no-cache")
            val f = flavor
            if (!f.isNullOrEmpty()) setRequestProperty("X-UniTrack-Flavor", f)
            doInput = true
        }
        currentConnection = conn
        try {
            val code = conn.responseCode
            if (code != 200) {
                Log.w(TAG, "stream HTTP $code")
                return
            }
            // Connected: reset backoff so the next reconnect (if it happens
            // immediately) doesn't wait 16s.
            backoffMs = 1_000L
            val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
            var lastEvent = ""
            while (running.get()) {
                val line = reader.readLine() ?: break
                when {
                    line.isEmpty() -> {
                        if (lastEvent == "config_changed") scheduleCoalescedCallback()
                        lastEvent = ""
                    }
                    line.startsWith(":") -> {
                        // SSE comment / heartbeat — ignore
                    }
                    line.startsWith("event:") -> {
                        lastEvent = line.substring("event:".length).trim()
                    }
                    // data: lines deliberately unread — host re-fetches the
                    // full config so the version hint adds nothing.
                }
            }
        } finally {
            try { conn.disconnect() } catch (_: Throwable) {}
            if (currentConnection === conn) currentConnection = null
        }
    }

    private fun buildUrl(): String {
        val f = flavor
        if (f.isNullOrEmpty()) return streamUrl
        val sep = if (streamUrl.contains("?")) "&" else "?"
        return "$streamUrl${sep}flavor=${java.net.URLEncoder.encode(f, "UTF-8")}"
    }

    // ─── coalesce ─────────────────────────────────────────────────────────

    private fun scheduleCoalescedCallback() {
        synchronized(coalesceLock) {
            if (pendingCallback) return
            pendingCallback = true
        }
        Thread({
            try { Thread.sleep(COALESCE_MS) } catch (_: InterruptedException) {}
            synchronized(coalesceLock) { pendingCallback = false }
            try { onConfigChanged?.invoke() }
            catch (e: Throwable) { Log.w(TAG, "onConfigChanged: ${e.message}") }
        }, "UniTrack-SSE-coalesce").also { it.isDaemon = true }.start()
    }

    // ─── lifecycle awareness ──────────────────────────────────────────────

    private var lifecycleWired = false
    private fun installLifecycle() {
        if (lifecycleWired) return
        UniTrack.addLifecycleListener { toForeground ->
            if (toForeground) {
                // Foreground: ensure the worker is alive (it might have hit
                // EOF while in background). spawnWorker is idempotent.
                if (running.get()) spawnWorker()
            } else {
                // Background: drop the connection so Android doesn't bill us
                // for a long-poll on a suspended app. The worker loop will
                // see running=true still and try to reconnect, but the
                // worker thread itself only respawns on foreground.
                try { currentConnection?.disconnect() } catch (_: Throwable) {}
                currentConnection = null
            }
        }
        lifecycleWired = true
    }
}
