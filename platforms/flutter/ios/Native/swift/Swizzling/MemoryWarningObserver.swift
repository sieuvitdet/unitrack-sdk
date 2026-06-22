// MemoryWarningObserver.swift
// Listens for system memory warnings and reports them to the SDK.

import UIKit

enum MemoryWarningObserver {
    static let installed: Void = {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            let used = currentMemoryUsage()
            let limit = ProcessInfo.processInfo.physicalMemory
            UniTrack.track("memory_warning", properties: [
                "memory_used":  used,
                "memory_limit": limit
            ])
        }
    }()

    static func install() { _ = installed }

    private static func currentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}
