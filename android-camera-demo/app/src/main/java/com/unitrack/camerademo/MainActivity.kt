package com.unitrack.camerademo

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.unitrack.camerademo.fragments.AlertsFragment
import com.unitrack.camerademo.fragments.CameraListFragment
import com.unitrack.camerademo.fragments.PairingFragment
import com.unitrack.camerademo.fragments.SettingsFragment
import com.unitrack.camerademo.fragments.VMSFragment

/**
 * 5-tab host. Same shape as the iOS demo's UITabBarController:
 *   Cameras  · VMS  · Add Camera (pairing)  · Alerts  · Settings.
 *
 * The SDK's ActivityTracker auto-emits screen_viewed/screen_exited based on
 * the current fragment's class name — see ut_screenName resolution on iOS,
 * and the analogous activity-class fallback on Android.
 */
class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val nav = findViewById<BottomNavigationView>(R.id.bottom_nav)
        nav.setOnItemSelectedListener { item ->
            val f: Fragment = when (item.itemId) {
                R.id.tab_cameras  -> CameraListFragment()
                R.id.tab_vms      -> VMSFragment()
                R.id.tab_pairing  -> PairingFragment()
                R.id.tab_alerts   -> AlertsFragment()
                R.id.tab_settings -> SettingsFragment()
                else              -> return@setOnItemSelectedListener false
            }
            supportFragmentManager.beginTransaction().replace(R.id.container, f).commit()
            true
        }
        if (savedInstanceState == null) nav.selectedItemId = R.id.tab_cameras
    }
}
