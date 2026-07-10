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

            // Field naming aligned with FPT application_context Iglu schema —
            // cross-platform keys match iOS so 1 schema validator + 1 SQL
            // query work for both platforms. Legacy aliases kept for
            // in-flight portal consumers.
            //   bundle           = packageName (iOS bundle_id sibling)
            //   device_model     = "Android" (generic family, same as iOS "iPhone"/"iPad")
            //   device_name      = "Samsung Galaxy S25 Ultra" (marketing-style label)
            //   device_imei      = ANDROID_ID (we don't request READ_PHONE_STATE)
            //   versioncode      = PackageInfo.versionCode (iOS CFBundleVersion sibling)
            //   network_label    = "wifi" / "5G" / "4G" / "3G" / "2G" / "ethernet"
            //   network_strength = WifiManager.connectionInfo.rssi (Wi-Fi only)
            val deviceId = androidId(app)
            val net = networkSnapshot(app)
            o.put("platform", "android")
            o.put("os", "Android")
            o.put("os_version", Build.VERSION.RELEASE ?: "")
            o.put("api_level", Build.VERSION.SDK_INT)
            // device_model = generic family; device_name = marketing label
            o.put("device_model", "Android")
            o.put("device_name", marketingDeviceName())
            o.put("model", Build.MODEL ?: "")                 // alias - hardware id
            o.put("manufacturer", Build.MANUFACTURER ?: "")
            o.put("app_name", appName)
            o.put("app_version", pi.versionName ?: "")
            o.put("app_build", versionCode(pi).toString())    // alias
            o.put("versioncode", versionCode(pi).toString())  // schema key
            // Cross-platform bundle key + legacy aliases
            o.put("bundle", pkg)                              // schema key
            o.put("app_bundle", pkg)                          // legacy alias
            o.put("app_package", pkg)                         // legacy alias
            o.put("bundle_id", pkg)                           // legacy alias
            o.put("locale", Locale.getDefault().toString())
            o.put("timezone", TimeZone.getDefault().id)
            o.put("screen", "${app.resources.displayMetrics.widthPixels}x" +
                            "${app.resources.displayMetrics.heightPixels}@" +
                            "${app.resources.displayMetrics.density}x")
            // Network — transport + friendly label + signal strength.
            o.put("network_type", net["type"] ?: "unknown")
            o.put("cellular_subtype", net["cellular_subtype"] ?: "")
            o.put("network_label", net["label"] ?: "")
            o.put("network_strength", net["strength"] ?: "")
            // Iglu schema application_context/1-0-0 khai 2 field này là string
            // ("true"/"false"), không phải boolean. Nếu put Boolean thẳng vào
            // JSONObject → validator Snowplow reject vào bad-events với
            // ValidationError: "boolean found, string expected". iOS đã cast
            // sẵn, giữ parity ở đây.
            o.put("is_debug", isDebuggable(app).toString())
            o.put("is_rooted", isRooted().toString())
            // device_imei: Android cấm READ_PHONE_STATE từ API 29+ trừ system app.
            // SDK fill bằng ANDROID_ID (Settings.Secure.ANDROID_ID) — stable
            // per app signing key + device, reset khi factory reset.
            o.put("device_imei", deviceId)                    // schema key
            o.put("device_id", deviceId)                      // legacy alias
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

    /** Marketing name from Build.MANUFACTURER + MODEL. Examples:
     *    "Samsung Galaxy S25 Ultra"
     *    "Google Pixel 9 Pro"
     *    "Xiaomi 14 Pro"
     *  Some OEMs already include the manufacturer in MODEL — we dedupe to
     *  avoid "Samsung Samsung Galaxy …".
     */
    private fun marketingDeviceName(): String {
        val manu = (Build.MANUFACTURER ?: "").trim()
        val model = (Build.MODEL ?: "").trim()
        if (manu.isEmpty()) return model
        if (model.isEmpty()) return manu
        if (model.lowercase(Locale.ROOT).startsWith(manu.lowercase(Locale.ROOT))) return model
        // Capitalize manufacturer first letter so "samsung Galaxy" → "Samsung Galaxy"
        val capManu = manu.replaceFirstChar { it.uppercase(Locale.ROOT) }
        return "$capManu $model"
    }

    /** Snapshot the active network. Returns a map with:
     *    type             — wifi | cellular | ethernet | none | unknown
     *    cellular_subtype — 2g | 3g | 4g | 5g (only when type=cellular)
     *    label            — friendly tag: "wifi" / "5G" / "4G" / "ethernet"
     *    strength         — Wi-Fi RSSI dBm (vd "-55"); empty for cellular
     *                       because Android doesn't expose RSSI without
     *                       READ_PHONE_STATE permission for non-system apps.
     */
    private fun networkSnapshot(app: Application): Map<String, String> = runCatching {
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return@runCatching mapOf("type" to "unknown")
        val net = cm.activeNetwork ?: return@runCatching mapOf("type" to "none")
        val caps = cm.getNetworkCapabilities(net) ?: return@runCatching mapOf("type" to "none")
        val out = mutableMapOf<String, String>()
        when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> {
                out["type"] = "wifi"
                out["label"] = "wifi"
                wifiRssi(app)?.let { out["strength"] = it.toString() }
            }
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> {
                val gen = cellularGeneration(app)
                out["type"] = "cellular"
                out["cellular_subtype"] = gen
                out["label"] = gen.uppercase()
            }
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> {
                out["type"] = "ethernet"
                out["label"] = "ethernet"
            }
            else -> {
                out["type"] = "other"
                out["label"] = "other"
            }
        }
        out
    }.getOrDefault(mapOf("type" to "unknown"))

    /** Wi-Fi RSSI in dBm via WifiManager. Returns null if location permission
     *  is missing (Android 10+ requires it for connectionInfo). */
    private fun wifiRssi(app: Application): Int? = runCatching {
        val wm = app.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager ?: return null
        @Suppress("DEPRECATION")
        wm.connectionInfo?.rssi?.takeIf { it != -127 }  // -127 = no connection / no permission
    }.getOrNull()

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
