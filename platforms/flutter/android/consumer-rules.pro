# UniTrack Flutter plugin — keep classes called from JNI (jni_bridge.cpp uses
# GetStaticMethodID to look up methods by name; R8 minify would rename them to
# single letters and JNI_OnLoad would throw NoSuchMethodError, crashing the app
# on the first NativeBridge.load()). Ship these rules with the plugin so any
# release build that consumes it via path/Maven gets them automatically.
-keep class com.unitrack.sdk.bridge.NativeBridge { *; }
-keepclassmembers class com.unitrack.sdk.bridge.NativeBridge {
    native <methods>;
}
-keep class com.unitrack.sdk.UniTrack { *; }
-keep class com.unitrack.sdk.UniTrackConfig { *; }
-keep class com.unitrack.sdk.UniTrackJson { *; }
-keep class com.unitrack.sdk.network.OkHttpTracker { *; }
