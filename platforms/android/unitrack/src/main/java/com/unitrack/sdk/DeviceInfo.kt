package com.unitrack.sdk

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.TimeZone

/**
 * Collects device + app metadata attached to every event (parity with what
 * Firebase auto-collects). Gathered once at init and handed to the C core via
 * NativeBridge.setDeviceInfo.
 *
 * `network_type` requires the ACCESS_NETWORK_STATE permission (declared in the
 * library manifest). If unavailable it degrades to "unknown" — never throws.
 */
internal object DeviceInfo {

    fun json(app: Application): String {
        val o = JSONObject()
        runCatching {
            val pkg = app.packageName
            val pm = app.packageManager
            val pi = pm.getPackageInfo(pkg, 0)
            // User-facing app title (android:label on the application tag in
            // AndroidManifest). Same idea as iOS CFBundleDisplayName — show
            // "Mobi X Staging" not just the package name.
            val appName = runCatching { pm.getApplicationLabel(app.applicationInfo)?.toString() ?: "" }
                .getOrDefault("")

            o.put("platform", "android")
            o.put("os", "Android")
            o.put("os_version", Build.VERSION.RELEASE ?: "")
            o.put("api_level", Build.VERSION.SDK_INT)
            o.put("model", Build.MODEL ?: "")
            o.put("device_name", Build.DEVICE ?: "")
            o.put("manufacturer", Build.MANUFACTURER ?: "")
            o.put("app_name", appName)
            o.put("app_version", pi.versionName ?: "")
            o.put("app_build", versionCode(pi).toString())
            // Cross-platform name (preferred for new portal queries) + an
            // Android-specific alias. bundle_id is kept = packageName for
            // back-compat with existing portal filters that read bundle_id.
            o.put("app_package", pkg)
            o.put("bundle_id", pkg)
            o.put("locale", Locale.getDefault().toString())
            o.put("timezone", TimeZone.getDefault().id)
            o.put("screen", "${app.resources.displayMetrics.widthPixels}x" +
                            "${app.resources.displayMetrics.heightPixels}@" +
                            "${app.resources.displayMetrics.density}x")
            o.put("network_type", networkType(app))
            o.put("is_debug", isDebuggable(app))
            o.put("is_rooted", isRooted())
            o.put("device_id", androidId(app))
            o.put("sdk_version", "1.0.0")
        }
        return o.toString()
    }

    @Suppress("DEPRECATION")
    private fun versionCode(pi: android.content.pm.PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()

    private fun isDebuggable(app: Application): Boolean =
        (app.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun androidId(app: Application): String =
        runCatching {
            Settings.Secure.getString(app.contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        }.getOrDefault("")

    private fun networkType(app: Application): String = runCatching {
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return@runCatching "unknown"
        val net = cm.activeNetwork ?: return@runCatching "none"
        val caps = cm.getNetworkCapabilities(net) ?: return@runCatching "none"
        when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)     -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> cellularGeneration(app)
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
    }.getOrDefault("unknown")

    /** Map the cellular data network type to a generation (2g/3g/4g/5g). */
    @Suppress("DEPRECATION")
    private fun cellularGeneration(app: Application): String = runCatching {
        val tm = app.getSystemService(Context.TELEPHONY_SERVICE)
            as? android.telephony.TelephonyManager ?: return@runCatching "cellular"
        // getDataNetworkType (API 30+) needs no permission; networkType is the
        // legacy fallback. A SecurityException degrades to plain "cellular".
        val type = try {
            if (Build.VERSION.SDK_INT >= 30) tm.dataNetworkType else tm.networkType
        } catch (_: SecurityException) {
            return@runCatching "cellular"
        }
        when (type) {
            android.telephony.TelephonyManager.NETWORK_TYPE_GPRS,
            android.telephony.TelephonyManager.NETWORK_TYPE_EDGE,
            android.telephony.TelephonyManager.NETWORK_TYPE_CDMA,
            android.telephony.TelephonyManager.NETWORK_TYPE_1xRTT,
            android.telephony.TelephonyManager.NETWORK_TYPE_IDEN -> "2g"
            android.telephony.TelephonyManager.NETWORK_TYPE_UMTS,
            android.telephony.TelephonyManager.NETWORK_TYPE_EVDO_0,
            android.telephony.TelephonyManager.NETWORK_TYPE_EVDO_A,
            android.telephony.TelephonyManager.NETWORK_TYPE_EVDO_B,
            android.telephony.TelephonyManager.NETWORK_TYPE_HSDPA,
            android.telephony.TelephonyManager.NETWORK_TYPE_HSUPA,
            android.telephony.TelephonyManager.NETWORK_TYPE_HSPA,
            android.telephony.TelephonyManager.NETWORK_TYPE_HSPAP,
            android.telephony.TelephonyManager.NETWORK_TYPE_EHRPD -> "3g"
            android.telephony.TelephonyManager.NETWORK_TYPE_LTE -> "4g"
            android.telephony.TelephonyManager.NETWORK_TYPE_NR -> "5g"
            else -> "cellular"
        }
    }.getOrDefault("cellular")

    /** Best-effort root detection: su binaries / known root packages / test-keys. */
    private fun isRooted(): Boolean {
        if (Build.TAGS?.contains("test-keys") == true) return true
        val paths = arrayOf(
            "/system/app/Superuser.apk", "/sbin/su", "/system/bin/su",
            "/system/xbin/su", "/data/local/xbin/su", "/data/local/bin/su",
            "/system/sd/xbin/su", "/system/bin/failsafe/su", "/data/local/su",
            "/su/bin/su", "/magisk"
        )
        return paths.any { runCatching { File(it).exists() }.getOrDefault(false) }
    }
}
