import Foundation

/// Bắt uncaught NSException và ghi vào core như một `crash` event.
///
/// CrashHandler của core chỉ cài signal handler ở tầng C++ (SIGSEGV/SIGABRT/
/// SIGBUS/SIGFPE/SIGILL/SIGTRAP). Phần lớn NSException cuối cùng cũng thành
/// SIGABRT nên signal handler thấy — nhưng lúc đó chỉ còn `SIGABRT`, mất sạch
/// tên class, reason và stack Objective-C. Handler này chạy TRƯỚC, nên crash
/// report có nội dung đọc được.
///
/// Parity: Android JvmCrashHandler.
enum NSExceptionHandler {

    private static var installed = false
    private static let lock = NSLock()

    /// Handler đã cài trước đó (Crashlytics/Sentry/host). Ghi đè là cướp crash
    /// của họ, nên luôn chuyền tiếp ở cuối.
    private static var previous: (@convention(c) (NSException) -> Void)?

    static func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            NSExceptionHandler.report(exception)
            NSExceptionHandler.previous?(exception)
        }
    }

    private static func report(_ e: NSException) {
        // Không dùng JSONSerialization: nó có thể ném, và đây là đường crash —
        // ném ở đây là nuốt luôn handler của host phía sau.
        let payload: [String: Any] = [
            "message": e.reason ?? e.name.rawValue,
            "type":    e.name.rawValue,
            "fatal":   true,
            // Giới hạn 100 frame — stack sâu (đệ quy) có thể hàng nghìn dòng.
            "stack":   e.callStackSymbols.prefix(100).joined(separator: "\n"),
            // Phân biệt với crash native để đội Data biết nguồn.
            "source":  "nsexception",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        UniTrack._logCrashToCore(json)
    }
}
