package com.unitrack.sdk.providers

import android.app.Application
import android.util.Log
import com.unitrack.sdk.UniTrack
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Generic HTTP analytics provider.
 *
 * Mục tiêu: gắn UniTrack lên Kibana / Elasticsearch / Logstash / OpenSearch /
 * backend FPT nội bộ trong 5 dòng config — không cần code transport, retry,
 * batch, offline. UniTrack lo hết qua [PendingQueue].
 *
 *   UniTrack.addHttpProvider(
 *       id        = "kibana",
 *       endpoint  = "https://kibana.fpt.vn/_bulk",
 *       format    = PayloadFormat.ELASTIC_BULK,
 *       headers   = mapOf("Authorization" to "ApiKey ..."),
 *       batchSize = 50,
 *   )
 *
 * Behaviour:
 *   - 2xx                   → SUCCESS (queue clears event for this provider)
 *   - 4xx (except 408/429)  → DROP    (schema sai — đừng loop)
 *   - 5xx / 408 / 429       → RETRY   (PendingQueue backoff exponential)
 *   - network/timeout       → RETRY
 *
 * Stamp session_id từ UniTrack core vào mọi event tự động.
 */
class HttpProvider(
    private val id: String,
    private val endpoint: String,
    private val format: PayloadFormat = PayloadFormat.JSON_SINGLE,
    private val headers: Map<String, String> = emptyMap(),
    private val batchSize: Int = 50,
    private val flushIntervalMs: Long = 30_000,
    private val connectTimeoutMs: Int = 10_000,
    private val readTimeoutMs: Int = 15_000,
) : AnalyticsProvider {

    override val providerId: String get() = id

    private val pending = ConcurrentLinkedQueue<JSONObject>()
    private val lastFlushAt = AtomicLong(0)
    private val exec = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ut-http-$id").apply { isDaemon = true }
    }
    private val resolvedHeaders: Map<String, String> = resolveHeaderSecrets(headers, id)

    override fun initialize(app: Application) { /* no SDK to wake */ }
    override fun track(name: String, properties: Map<String, Any?>) {
        // Default fall-through (send() is the real entry point).
        send(name, properties)
    }
    override fun setUser(userId: String?, traits: Map<String, Any?>) { /* no-op */ }
    override fun setScreen(name: String) { /* no-op */ }

    override fun send(name: String, properties: Map<String, Any?>): ProviderResult {
        val event = stamp(name, properties)
        return when (format) {
            PayloadFormat.JSON_SINGLE -> postOne(event)
            PayloadFormat.JSON_LINES,
            PayloadFormat.JSON_ARRAY,
            PayloadFormat.ELASTIC_BULK -> bufferAndMaybeFlush(event)
        }
    }

    private fun stamp(name: String, properties: Map<String, Any?>): JSONObject {
        val o = JSONObject(properties.mapValues { it.value ?: JSONObject.NULL })
        o.put("event_name", name)
        try {
            o.put("session_id", UniTrack.currentSessionId())
            o.put("session_index", UniTrack.sessionIndex())
        } catch (_: Throwable) { /* before init */ }
        if (!o.has("timestamp")) o.put("timestamp", System.currentTimeMillis())
        // W3C: stamp trace_id ở event-level khi tracing bật ở remote config,
        // join với backend log / Snowplow / Firebase qua cùng 1 mã. HTTP-header
        // injection vẫn do UniTrackTracingInterceptor lo allowlist riêng.
        try {
            if (UniTrack.tracingSnapshot().enabled && !o.has("trace_id")) {
                val (traceId, spanId) =
                    com.unitrack.sdk.bridge.NativeBridge.newTrace()
                o.put("trace_id", traceId)
                o.put("span_id",  spanId)
            }
        } catch (_: Throwable) { /* native not loaded yet */ }
        return o
    }

    private fun bufferAndMaybeFlush(event: JSONObject): ProviderResult {
        pending.add(event)
        val now = System.currentTimeMillis()
        val due = pending.size >= batchSize ||
                  (now - lastFlushAt.get()) >= flushIntervalMs
        if (!due) return ProviderResult.SUCCESS  // batched, will leave on next flush
        return flushBatch()
    }

    /** Force a flush — exposed for tests / lifecycle. */
    fun flush(): ProviderResult = flushBatch()

    private fun flushBatch(): ProviderResult {
        val batch = mutableListOf<JSONObject>()
        while (batch.size < batchSize) {
            batch.add(pending.poll() ?: break)
        }
        if (batch.isEmpty()) return ProviderResult.SUCCESS
        lastFlushAt.set(System.currentTimeMillis())
        val body = when (format) {
            PayloadFormat.JSON_LINES   -> batch.joinToString("\n") { it.toString() }
            PayloadFormat.JSON_ARRAY   -> JSONArray(batch).toString()
            PayloadFormat.ELASTIC_BULK -> batch.joinToString("\n") {
                """{"index":{}}""" + "\n" + it.toString()
            } + "\n"
            PayloadFormat.JSON_SINGLE  -> batch.first().toString()
        }
        val contentType = when (format) {
            PayloadFormat.ELASTIC_BULK, PayloadFormat.JSON_LINES -> "application/x-ndjson"
            else -> "application/json"
        }
        val r = post(body, contentType)
        if (r != ProviderResult.SUCCESS) {
            // Put events back so PendingQueue replays them; we don't want to
            // double-buffer between in-memory pending + on-disk PendingQueue.
            batch.forEach { pending.offer(it) }
        }
        return r
    }

    private fun postOne(event: JSONObject): ProviderResult {
        return post(event.toString(), "application/json")
    }

    private fun post(body: String, contentType: String): ProviderResult {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = connectTimeoutMs
                readTimeout    = readTimeoutMs
                doOutput = true
                setRequestProperty("Content-Type", contentType)
                for ((k, v) in resolvedHeaders) setRequestProperty(k, v)
            }
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            when {
                code in 200..299           -> ProviderResult.SUCCESS
                code == 408 || code == 429 -> ProviderResult.RETRY
                code in 500..599           -> ProviderResult.RETRY
                code in 400..499           -> {
                    Log.w("UTHttpProvider", "$id 4xx ($code) → DROP")
                    ProviderResult.DROP
                }
                else                       -> ProviderResult.RETRY
            }
        } catch (e: Throwable) {
            Log.w("UTHttpProvider", "$id network error: ${e.message} → RETRY")
            ProviderResult.RETRY
        } finally {
            conn?.disconnect()
        }
    }

    companion object {
        /**
         * Resolve `${ENV_FOO}` placeholders trong header VALUES bằng env vars.
         * Cho phép Portal lưu reference non-secret kiểu `${ENV_KIBANA_KEY}`
         * thay vì raw API key — app/process set thật ở launch (gradle BuildConfig
         * → System.setProperty, hoặc k8s/Docker env). Unmatched → giữ literal,
         * log 1 lần. Header KEYS không đổi.
         */
        private val PLACEHOLDER = Regex("""\$\{ENV_([A-Z0-9_]+)\}""")

        @JvmStatic
        fun resolveHeaderSecrets(headers: Map<String, String>, providerId: String): Map<String, String> {
            val env = System.getenv()
            return headers.mapValues { (k, v) ->
                PLACEHOLDER.replace(v) { m ->
                    val name = "ENV_" + m.groupValues[1]
                    env[name] ?: run {
                        Log.w("UTHttpProvider", "$providerId header $k missing env $name")
                        m.value
                    }
                }
            }
        }
    }
}

enum class PayloadFormat {
    /** 1 event = 1 POST as a single JSON object. Simplest backends. */
    JSON_SINGLE,
    /** Batched: NDJSON, 1 line per event. */
    JSON_LINES,
    /** Batched: a JSON array per POST. */
    JSON_ARRAY,
    /** Elasticsearch `_bulk` API: action line + doc line, NDJSON, trailing newline. */
    ELASTIC_BULK,
}
