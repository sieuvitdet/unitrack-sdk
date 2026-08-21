package com.unitrack.sdk.lifecycle

import com.unitrack.sdk.bridge.NativeBridge
import org.json.JSONObject

/**
 * Bắt uncaught Java/Kotlin exception và ghi vào core như một `crash` event.
 *
 * Core chỉ cài signal handler ở tầng C++ (SIGSEGV/SIGABRT/SIGBUS/SIGFPE/
 * SIGILL/SIGTRAP), nên nó KHÔNG thấy NPE, IndexOutOfBounds hay bất kỳ
 * exception nào của JVM — nhóm crash phổ biến nhất của app Android. Trước đây
 * chỗ trống đó do Snowplow `exceptionAutotracking` lấp, nghĩa là dự án nào
 * không dùng Snowplow thì mất trắng crash JVM. SDK phải tự lo, provider chỉ
 * bổ trợ.
 *
 * Chain handler cũ: Crashlytics/Sentry/host đều có thể đã cài một cái. Ghi đè
 * là cướp crash của họ, nên luôn gọi lại cái trước đó ở cuối.
 */
internal object JvmCrashHandler {

    @Volatile private var installed = false

    fun install() {
        if (installed) return
        installed = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                NativeBridge.logCrash(buildCrashJson(thread, throwable))
            } catch (_: Throwable) {
                // Báo cáo crash mà tự crash thì nuốt process trước khi handler
                // cũ kịp chạy — im lặng bỏ qua, việc chính là chuyền tiếp.
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    private fun buildCrashJson(thread: Thread, t: Throwable): String {
        // Nguyên nhân gốc mới là thứ đáng báo: wrapper như
        // InvocationTargetException / RuntimeException che mất lỗi thật.
        var root: Throwable = t
        var guard = 0
        while (root.cause != null && root.cause !== root && guard++ < 16) {
            root = root.cause!!
        }
        return JSONObject().apply {
            put("message", root.message ?: root.javaClass.name)
            put("type", root.javaClass.name)
            put("fatal", true)
            put("thread", thread.name)
            put("stack", stackOf(root))
            // Phân biệt với crash native để đội Data biết nguồn.
            put("source", "jvm")
        }.toString()
    }

    /** Giới hạn 100 frame — stack sâu (đệ quy vô hạn) có thể hàng nghìn dòng. */
    private fun stackOf(t: Throwable): String =
        t.stackTrace.take(100).joinToString("\n") { "  at $it" }
}
