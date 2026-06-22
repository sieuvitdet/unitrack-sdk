package com.unitrack.sdk

import android.app.Activity
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream

/**
 * Snapshot of the current Activity's view tree — every View with its type,
 * window-relative frame, and label/id when known. Stored as a gzipped
 * base64 string on the `screen_layout` event so the portal can render the
 * actual screen outline (including custom widgets and overrides).
 *
 * Trigger: app calls `UniTrackWireframe.snapshot(activity)` once per screen
 * — typically inside the existing ActivityTracker.onActivityResumed path.
 * Auto-install is not done from here so revisits don't re-walk the same
 * tree (each call adds ~2-10KB of payload).
 *
 * Truncates at [maxNodes] = 500; beyond that, children are skipped and
 * `truncated: true` is set on the event.
 */
object UniTrackWireframe {

    @JvmField var maxNodes: Int = 500

    @JvmStatic
    fun snapshot(activity: Activity) {
        val root = activity.window?.decorView ?: return
        // Walk on the UI thread — Android requires it for View access.
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            emit(root)
        } else {
            activity.runOnUiThread { emit(root) }
        }
    }

    private fun emit(root: View) {
        val counter = IntArray(1)
        val tree = walk(root, counter)
        val truncated = counter[0] >= maxNodes
        val json = tree.toString()
        val gz = gzip(json.toByteArray(Charsets.UTF_8)) ?: return
        val b64 = android.util.Base64.encodeToString(gz, android.util.Base64.NO_WRAP)
        UniTrack.track("screen_layout", mapOf(
            "tree_b64gz" to b64,
            "node_count" to counter[0],
            "truncated"  to truncated,
            "framework"  to "android",
        ))
    }

    private fun walk(view: View, counter: IntArray): JSONObject {
        counter[0]++
        val rect = Rect()
        view.getGlobalVisibleRect(rect)
        val node = JSONObject()
        node.put("id",   counter[0])
        node.put("type", view.javaClass.simpleName)
        node.put("x",    rect.left)
        node.put("y",    rect.top)
        node.put("w",    rect.width())
        node.put("h",    rect.height())
        if (view.visibility != View.VISIBLE) node.put("hidden", true)
        if (view.alpha < 0.99f) node.put("alpha", view.alpha.toDouble())
        if (view.id != View.NO_ID) {
            runCatching {
                node.put("aid", view.resources.getResourceEntryName(view.id))
            }
        }
        if (view is TextView) {
            val txt = view.text?.toString()
            if (!txt.isNullOrEmpty()) node.put("text", trim(txt))
        }
        if (counter[0] >= maxNodes) return node

        if (view is ViewGroup && view.childCount > 0) {
            val children = JSONArray()
            for (i in 0 until view.childCount) {
                children.put(walk(view.getChildAt(i), counter))
                if (counter[0] >= maxNodes) break
            }
            if (children.length() > 0) node.put("children", children)
        }
        return node
    }

    private fun trim(s: String): String =
        if (s.length > 64) s.substring(0, 63) + "…" else s

    private fun gzip(bytes: ByteArray): ByteArray? = runCatching {
        val baos = ByteArrayOutputStream(bytes.size / 2)
        GZIPOutputStream(baos).use { it.write(bytes) }
        baos.toByteArray()
    }.getOrNull()
}
