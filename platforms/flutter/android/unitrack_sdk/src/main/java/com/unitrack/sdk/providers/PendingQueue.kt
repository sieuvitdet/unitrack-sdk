package com.unitrack.sdk.providers

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * Per-provider ack offline queue for binding-side providers.
 *
 * Why this exists separately from the C++ core OfflineQueue:
 *   - The C++ queue serves UniTrack Portal HTTP only. It doesn't know about
 *     Snowplow / Firebase / HttpProvider, which live in the Kotlin layer.
 *   - Each event needs a per-provider ack bitmask so we can: success on
 *     Firebase → drop bit, still retry HttpProvider → keep bit.
 *
 * Schema:
 *   pending_events(
 *     id INTEGER PRIMARY KEY AUTOINCREMENT,
 *     name TEXT,
 *     props_json TEXT,
 *     pending_mask INTEGER,        -- bitmask: 1 bit per provider id
 *     retry_count INTEGER DEFAULT 0,
 *     next_retry_at INTEGER DEFAULT 0,
 *     created_at INTEGER
 *   )
 *
 *   provider_slots(
 *     provider_id TEXT PRIMARY KEY,
 *     bit_index INTEGER
 *   )
 *
 * Retry policy mirrors Snowplow native + GA4 industry-grade:
 *   - base 1s, exponential, cap 5 minutes per attempt
 *   - max 10 retries / event → DROP
 *   - TTL 7 days → DROP
 *   - cap 10 MB → FIFO evict
 */
internal class PendingQueue(ctx: Context) {

    private val helper = Helper(ctx.applicationContext)
    private val mu = Any()

    // provider_id → bit index (stable, persisted).
    private val slots = HashMap<String, Int>()
    private val nextBit = AtomicLong(0)

    init {
        loadSlots()
    }

    /** Reserve (or look up) a stable bit index for [providerId]. */
    fun bitFor(providerId: String): Int = synchronized(mu) {
        slots[providerId]?.let { return it }
        val db = helper.writableDatabase
        val cur = db.rawQuery("SELECT bit_index FROM provider_slots WHERE provider_id=?", arrayOf(providerId))
        cur.use {
            if (it.moveToFirst()) {
                val bit = it.getInt(0)
                slots[providerId] = bit
                if (bit >= nextBit.get()) nextBit.set((bit + 1).toLong())
                return bit
            }
        }
        val bit = nextBit.getAndIncrement().toInt()
        if (bit >= 63) {
            Log.w(TAG, "provider slot overflow ($providerId) — capped at 63, retry will be lossy")
        }
        db.execSQL("INSERT INTO provider_slots(provider_id, bit_index) VALUES(?, ?)",
            arrayOf<Any>(providerId, bit))
        slots[providerId] = bit
        bit
    }

    /** Enqueue an event that has pending delivery to [providerIds]. */
    fun enqueue(name: String, properties: Map<String, Any?>, providerIds: List<String>) {
        if (providerIds.isEmpty()) return
        var mask = 0L
        for (pid in providerIds) mask = mask or (1L shl bitFor(pid))
        val v = ContentValues().apply {
            put("name", name)
            put("props_json", toJson(properties))
            put("pending_mask", mask)
            put("retry_count", 0)
            put("next_retry_at", 0L)
            put("created_at", System.currentTimeMillis())
        }
        synchronized(mu) {
            helper.writableDatabase.insert("pending_events", null, v)
        }
    }

    data class Pending(
        val rowId: Long,
        val name: String,
        val properties: Map<String, Any?>,
        val pendingMask: Long,
        val retryCount: Int,
    )

    /** Pop up to [max] events ready for retry (next_retry_at <= now). */
    fun peek(max: Int): List<Pending> = synchronized(mu) {
        val now = System.currentTimeMillis()
        val out = mutableListOf<Pending>()
        helper.readableDatabase.rawQuery(
            "SELECT id,name,props_json,pending_mask,retry_count FROM pending_events " +
                "WHERE next_retry_at <= ? ORDER BY id ASC LIMIT ?",
            arrayOf(now.toString(), max.toString())
        ).use { c ->
            while (c.moveToNext()) {
                out.add(Pending(
                    rowId       = c.getLong(0),
                    name        = c.getString(1),
                    properties  = fromJson(c.getString(2)),
                    pendingMask = c.getLong(3),
                    retryCount  = c.getInt(4),
                ))
            }
        }
        out
    }

    /**
     * Update event after a delivery attempt:
     *   - successful providers → clear their bits
     *   - retry providers      → keep their bits, bump retry_count, schedule next
     *   - drop providers       → clear their bits (treat as success — give up)
     *
     * If pending_mask becomes 0 → row is deleted.
     */
    fun ack(
        rowId: Long,
        successful: List<String>,
        retrying: List<String>,
        dropped: List<String>,
        currentMask: Long,
        currentRetry: Int,
    ) {
        var mask = currentMask
        for (pid in successful) mask = mask and (1L shl bitFor(pid)).inv()
        for (pid in dropped)    mask = mask and (1L shl bitFor(pid)).inv()
        // retrying bits stay set
        synchronized(mu) {
            val db = helper.writableDatabase
            if (mask == 0L) {
                db.delete("pending_events", "id=?", arrayOf(rowId.toString()))
                return
            }
            val retry = currentRetry + 1
            if (retry >= MAX_RETRIES) {
                Log.w(TAG, "drop after $retry retries rowId=$rowId mask=$mask")
                db.delete("pending_events", "id=?", arrayOf(rowId.toString()))
                return
            }
            val backoff = backoffMs(retry)
            val v = ContentValues().apply {
                put("pending_mask", mask)
                put("retry_count", retry)
                put("next_retry_at", System.currentTimeMillis() + backoff)
            }
            db.update("pending_events", v, "id=?", arrayOf(rowId.toString()))
        }
    }

    /** Total events currently waiting. */
    fun count(): Int = synchronized(mu) {
        helper.readableDatabase.rawQuery("SELECT COUNT(*) FROM pending_events", null).use {
            if (it.moveToFirst()) it.getInt(0) else 0
        }
    }

    /** Enforce TTL + size cap. Call periodically (vd worker tick). */
    fun trim() {
        synchronized(mu) {
            val db = helper.writableDatabase
            val cutoff = System.currentTimeMillis() - TTL_MS
            db.delete("pending_events", "created_at < ?", arrayOf(cutoff.toString()))
            val cnt = count()
            if (cnt > MAX_EVENTS) {
                db.execSQL(
                    "DELETE FROM pending_events WHERE id IN (" +
                        "SELECT id FROM pending_events ORDER BY id ASC LIMIT ?)",
                    arrayOf<Any>(cnt - MAX_EVENTS))
            }
        }
    }

    private fun loadSlots() = synchronized(mu) {
        helper.readableDatabase.rawQuery("SELECT provider_id, bit_index FROM provider_slots", null).use {
            while (it.moveToNext()) {
                val pid = it.getString(0); val bit = it.getInt(1)
                slots[pid] = bit
                if (bit >= nextBit.get()) nextBit.set((bit + 1).toLong())
            }
        }
    }

    private fun toJson(m: Map<String, Any?>): String =
        JSONObject(m.mapValues { it.value ?: JSONObject.NULL }).toString()

    private fun fromJson(s: String): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        val o = JSONObject(s)
        for (k in o.keys()) {
            val v = o.opt(k); out[k] = if (v === JSONObject.NULL) null else v
        }
        return out
    }

    companion object {
        private const val TAG = "UTPendingQueue"
        private const val MAX_RETRIES = 10
        private const val MAX_EVENTS = 20_000          // ~10 MB at ~500 B/event
        private const val TTL_MS = 7 * 24 * 3600 * 1000L
        private const val BACKOFF_BASE_MS = 1_000L     // 1s
        private const val BACKOFF_MAX_MS  = 300_000L   // 5 min

        fun backoffMs(retry: Int): Long {
            val base = (BACKOFF_BASE_MS * 2.0.pow(retry - 1)).toLong()
            val capped = min(base, BACKOFF_MAX_MS)
            // ±20% jitter
            val jitter = (capped * (Random.nextDouble() * 0.4 - 0.2)).toLong()
            return capped + jitter
        }
    }

    private class Helper(ctx: Context) : SQLiteOpenHelper(ctx, "unitrack_pending.db", null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("""
                CREATE TABLE pending_events(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL,
                  props_json TEXT NOT NULL,
                  pending_mask INTEGER NOT NULL,
                  retry_count INTEGER NOT NULL DEFAULT 0,
                  next_retry_at INTEGER NOT NULL DEFAULT 0,
                  created_at INTEGER NOT NULL
                )""".trimIndent())
            db.execSQL("CREATE INDEX idx_next_retry ON pending_events(next_retry_at)")
            db.execSQL("""
                CREATE TABLE provider_slots(
                  provider_id TEXT PRIMARY KEY,
                  bit_index INTEGER NOT NULL
                )""".trimIndent())
        }

        override fun onUpgrade(db: SQLiteDatabase, oldV: Int, newV: Int) { /* v1 only */ }
    }
}
