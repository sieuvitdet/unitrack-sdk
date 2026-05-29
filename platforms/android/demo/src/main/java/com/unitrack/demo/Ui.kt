package com.unitrack.demo

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import androidx.core.view.setPadding

/**
 * Tiny code-built UI helpers (no XML layouts needed for the screens).
 *
 * Auto-capture key: every interactive view gets its `tag` set to a readable
 * string. UniTrack's ClickTracker resolves the tap element_key in this order —
 * `view.tag` (String) FIRST, then android:id resource name, contentDescription,
 * text, class. Since we build views in code (no R.id), the String tag is the
 * reliable way to get clean keys like `stream_start` in the portal.
 */
object Ui {

    /** A full-width button. [key] becomes the tap element_key (set as the tag). */
    fun button(ctx: Context, title: String, key: String, onTap: () -> Unit): Button {
        val b = Button(ctx)
        b.text = title
        b.isAllCaps = false
        b.tag = key                          // ← tap element_key (priority 1)
        b.setOnClickListener { onTap() }
        return b
    }

    /** A label + Switch row. The switch's tag becomes the tap element_key. */
    fun switchRow(ctx: Context, title: String, key: String, onChange: (Boolean) -> Unit): View {
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ctx, 8))
        }
        val label = TextView(ctx).apply {
            text = title
            textSize = 16f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val sw = Switch(ctx).apply {
            tag = key
            setOnCheckedChangeListener { _, isOn -> onChange(isOn) }
        }
        row.addView(label)
        row.addView(sw)
        return row
    }

    fun header(ctx: Context, title: String): TextView = TextView(ctx).apply {
        text = title
        textSize = 20f
        setPadding(0, dp(ctx, 4), 0, dp(ctx, 12))
    }

    /** A scrollable vertical stack filling the screen. */
    fun screen(ctx: Context, children: List<View>): View {
        val stack = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 16))
            children.forEach { child ->
                addView(child, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(ctx, 6) })
            }
        }
        return ScrollView(ctx).apply { addView(stack) }
    }

    fun dp(ctx: Context, v: Int): Int =
        (v * ctx.resources.displayMetrics.density).toInt()
}
