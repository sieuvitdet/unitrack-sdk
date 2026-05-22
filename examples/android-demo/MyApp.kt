package com.example.demo

import android.app.Application
import com.unitrack.sdk.UniTrack
import com.unitrack.sdk.UniTrackConfig
import com.unitrack.sdk.network.OkHttpTracker
import okhttp3.OkHttpClient

class MyApp : Application() {

    lateinit var http: OkHttpClient

    override fun onCreate() {
        super.onCreate()

        UniTrack.initialize(this, UniTrackConfig(
            apiKey       = "YOUR_API_KEY",
            endpoint     = "https://ingest.example.com/v1/events",
            samplingRate = 1.0
        ))

        // For network tracking of your custom OkHttp client:
        http = OkHttpTracker.attach(OkHttpClient())

        // After login:
        // UniTrack.identify("user-123", mapOf("plan" to "pro"))
    }
}

// In each Activity, tag your views so taps get meaningful keys:
//
//   <Button android:id="@+id/home_buy_now_btn" .../>
//
// Screen tracking is automatic from ActivityLifecycleCallbacks.
// Fragments resumed via FragmentManager are also tracked.
//
// Safe JSON parsing:
//
//   val obj = UniTrackJson.parse("UserDTO", responseText)
