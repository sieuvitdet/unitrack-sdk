package com.unitrack.demo

import android.os.Bundle
import android.view.View
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import com.google.android.material.bottomnavigation.BottomNavigationView

/**
 * Five-tab host (mirrors the iOS RootTabBarController): Cameras / VMS / Add
 * Camera / Alerts / Settings. Each tab is a distinct Fragment, so the SDK
 * auto-captures a `screen_view` named after each Fragment class as you switch.
 */
class MainActivity : AppCompatActivity() {

    private val container = View.generateViewId()

    private val tabs = listOf(
        Tab("Cameras", ::CamerasFragment),
        Tab("VMS", ::VmsFragment),
        Tab("Thêm camera", ::PairingFragment),
        Tab("Cảnh báo", ::AlertsFragment),
        Tab("Cài đặt", ::SettingsFragment),
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = FrameLayout(this)
        val host = FrameLayout(this).apply { id = container }
        val nav = BottomNavigationView(this).apply {
            tabs.forEachIndexed { i, t -> menu.add(0, i, i, t.title) }
            setOnItemSelectedListener { item ->
                show(tabs[item.itemId]); true
            }
        }
        root.addView(host, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT,
        ).apply { bottomMargin = Ui.dp(this@MainActivity, 56) })
        root.addView(nav, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, Ui.dp(this, 56),
        ).apply { gravity = android.view.Gravity.BOTTOM })
        setContentView(root)

        if (savedInstanceState == null) show(tabs[0])
    }

    private fun show(tab: Tab) {
        supportFragmentManager.beginTransaction()
            .replace(container, tab.create())
            .commit()
    }

    private class Tab(val title: String, val create: () -> Fragment)
}
