package com.example.host

import android.app.Application
import android.util.Log
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactNativeHost
import com.facebook.react.ReactPackage
import com.facebook.react.defaults.DefaultReactNativeHost
import com.unitrack.rn.RNUniTrackPackage
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.UniTrackConfig

// Native host app. Init UniTrack TRƯỚC ReactNativeHost để singleton đã sẵn
// khi RN bridge dựng. RN plugin gọi UniTrack.customTrack(...) qua import
// trực tiếp — JVM classloader resolve về class NÀY (compileOnly ở RN
// plugin ép runtime bind vào host).

class MainApplication : Application(), ReactApplication {

    private val nativeHost = object : DefaultReactNativeHost(this) {
        override fun getPackages(): List<ReactPackage> {
            // Manual list vì bỏ autolink cho test bed tối giản.
            return listOf(
                com.facebook.react.shell.MainReactPackage(),
                RNUniTrackPackage(),
            )
        }
        override fun getJSMainModuleName(): String = "index"
        override fun getUseDeveloperSupport(): Boolean = BuildConfig.DEBUG
    }

    override fun getReactNativeHost(): ReactNativeHost = nativeHost

    override fun onCreate() {
        super.onCreate()

        val cfg = UniTrackConfig(
            apiKey    = "utk_rn_cross_binary_test",
            endpoint  = "https://event-tracking-portal.mobix.asia/ingest",
            batchSize = 20,
            flushIntervalMs = 3000,
        )
        UniTrack.initialize(this, cfg)
        Log.i("UniTrackHost",
            "initialized session_id=${UniTrack.currentSessionId()} idx=${UniTrack.sessionIndex()}")
    }
}
