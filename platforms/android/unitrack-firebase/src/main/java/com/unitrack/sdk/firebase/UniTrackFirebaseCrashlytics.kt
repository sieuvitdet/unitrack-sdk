package com.unitrack.sdk.firebase

import com.unitrack.sdk.UniTrack

/**
 * Thin façade: app calls 1 API, Crashlytics records the error AND UniTrack
 * fires `application_error` through its convention pipeline (portal +
 * Snowplow). The C++ signal-trap crash handler in UniTrack core stays
 * independent — it fires on next launch with reason=signal — while this
 * helper handles non-fatal try/catch recordError() calls inline.
 *
 * Usage:
 *   try { riskyCall() }
 *   catch (e: Throwable) { UniTrackFirebaseCrashlytics.recordError(e) }
 *
 * Breadcrumb log + custom keys (features the C++ trap can't replicate from
 * a signal handler):
 *   UniTrackFirebaseCrashlytics.log("entering checkout flow step 2")
 *   UniTrackFirebaseCrashlytics.setCustomKey("cart_size", 3)
 *
 * Uses reflection so this module compiles even if the host app doesn't
 * include firebase-crashlytics — calls become no-ops + fall through to
 * UniTrack reporting only.
 */
object UniTrackFirebaseCrashlytics {

    /** Record a non-fatal error. Forwards to Crashlytics for symbolication +
     *  fires `application_error` (is_fatal=false) so the portal + Snowplow
     *  see the same incident. */
    @JvmStatic
    @JvmOverloads
    fun recordError(error: Throwable, context: Map<String, Any?> = emptyMap()) {
        // Set custom keys first so they appear on the Crashlytics report.
        for ((k, v) in context) setCustomKey(k, v ?: "")
        recordErrorReflective(error)

        val props = mutableMapOf<String, Any?>(
            "message"  to (error.message ?: error.javaClass.simpleName),
            "is_fatal" to false,
            "exception_name" to error.javaClass.simpleName,
        )
        if (context.isNotEmpty()) props["context"] = context
        UniTrack.track("application_error", props)
    }

    /** Attach a custom key to subsequent crash reports (breadcrumb context).
     *  Mirrors FirebaseCrashlytics.setCustomKey(key, value). */
    @JvmStatic
    fun setCustomKey(key: String, value: Any) {
        runCatching {
            val cls = Class.forName("com.google.firebase.crashlytics.FirebaseCrashlytics")
            val instance = cls.getMethod("getInstance").invoke(null) ?: return
            // setCustomKey is overloaded — find the variant matching value type.
            val method = when (value) {
                is String  -> cls.getMethod("setCustomKey", String::class.java, String::class.java)
                is Boolean -> cls.getMethod("setCustomKey", String::class.java, Boolean::class.javaPrimitiveType)
                is Int     -> cls.getMethod("setCustomKey", String::class.java, Int::class.javaPrimitiveType)
                is Long    -> cls.getMethod("setCustomKey", String::class.java, Long::class.javaPrimitiveType)
                is Float   -> cls.getMethod("setCustomKey", String::class.java, Float::class.javaPrimitiveType)
                is Double  -> cls.getMethod("setCustomKey", String::class.java, Double::class.javaPrimitiveType)
                else       -> cls.getMethod("setCustomKey", String::class.java, String::class.java)
            }
            val arg: Any = if (method.parameterTypes[1] == String::class.java) value.toString() else value
            method.invoke(instance, key, arg)
        }
    }

    /** Append a line to the Crashlytics log ring buffer. Surfaces in the
     *  crash report's "Logs" section. */
    @JvmStatic
    fun log(message: String) {
        runCatching {
            val cls = Class.forName("com.google.firebase.crashlytics.FirebaseCrashlytics")
            val instance = cls.getMethod("getInstance").invoke(null) ?: return
            cls.getMethod("log", String::class.java).invoke(instance, message)
        }
    }

    /** Sync the identified user id into Crashlytics. Called by FirebaseProvider
     *  from setUser() so crash reports attribute to the same identity
     *  Analytics segments by. Public so test code can poke it directly. */
    @JvmStatic
    fun syncUser(userId: String?) {
        runCatching {
            val cls = Class.forName("com.google.firebase.crashlytics.FirebaseCrashlytics")
            val instance = cls.getMethod("getInstance").invoke(null) ?: return
            // setUserId accepts "" as the cleared state.
            cls.getMethod("setUserId", String::class.java).invoke(instance, userId ?: "")
        }
    }

    private fun recordErrorReflective(error: Throwable) {
        runCatching {
            val cls = Class.forName("com.google.firebase.crashlytics.FirebaseCrashlytics")
            val instance = cls.getMethod("getInstance").invoke(null) ?: return
            cls.getMethod("recordException", Throwable::class.java).invoke(instance, error)
        }
    }
}
