# UniTrack SDK — keep public API and JNI bridge.
-keep class com.unitrack.sdk.UniTrack { *; }
-keep class com.unitrack.sdk.UniTrackConfig { *; }
-keep class com.unitrack.sdk.UniTrackJson { *; }
-keep class com.unitrack.sdk.bridge.NativeBridge { *; }
-keepclassmembers class com.unitrack.sdk.bridge.NativeBridge {
    native <methods>;
}
-keep class com.unitrack.sdk.network.OkHttpTracker { *; }
