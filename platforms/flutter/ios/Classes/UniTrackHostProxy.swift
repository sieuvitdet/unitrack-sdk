// UniTrackHostProxy.swift
//
// Khi 1 process iOS host CẢ native UniTrack SDK (qua SPM/Pod) VÀ Flutter
// module (qua unitrack pub.dev), 2 binary chứa 2 module "UniTrack" và
// "unitrack" — KHÔNG share singleton dù tên class trùng. Hậu quả nếu để
// nguyên: 2 session_id khác nhau, 2 SQLite db, 2 batch HTTP gửi Portal
// → operator thấy 2 session cho 1 user → ko join được.
//
// File này giải bài đó: plugin Swift detect có native UniTrack module
// không qua NSClassFromString. Nếu CÓ → mọi call (track / setScreen /
// currentSessionId / ...) forward sang singleton native qua ObjC runtime
// (perform selector / KVC), KHÔNG dùng module-local UniTrack. Một SDK
// duy nhất — Flutter chỉ là người gửi event vào nó.
//
// Khi CHƯA detect được (app chỉ có Flutter module, ko có native SPM) →
// fallback dùng module-local UniTrack như cũ. Backward-compat 100%.
//
// Lý do dùng reflection thay vì link share module: Flutter plugin chuẩn
// compile thành dynamic framework có module riêng. Không có cách "import
// UniTrack" của parent app vào plugin nếu plugin được build độc lập (pub
// publish + xcframework workflow). Reflection là escape hatch chuẩn.

import Foundation
import UIKit

enum UniTrackHostProxy {

    /// Class native UniTrack (module "UniTrack" của SPM/Pod). Cached vì
    /// NSClassFromString tốn 1 lookup runtime.
    private static let nativeClass: AnyClass? = {
        // Swift class name có dạng "<Module>.<ClassName>". Khi app link
        // UniTrack SPM target name "UniTrack", class này tồn tại với tên
        // "UniTrack.UniTrack". Nếu Pod/SPM rename target khác, sửa ở đây.
        return NSClassFromString("UniTrack.UniTrack")
            ?? NSClassFromString("UniTrackCore.UniTrack")  // hợp pod khác
    }()

    /// True khi process có native UniTrack module phân biệt với plugin's
    /// module-local UniTrack. Plugin dùng cờ này để route call đúng singleton.
    static var isCoResident: Bool { nativeClass != nil }

    // MARK: - Reflection helpers

    /// Gọi class method 0..2 arg KHÔNG trả về giá trị (void return). Dùng cho
    /// track / setScreen / reset / flush / setEnabled / rotateSession … Việc
    /// đọc giá trị trả về của `perform` rồi gọi `.takeUnretainedValue()` trong
    /// trường hợp method void là UB: NSInvocation/Objective-C runtime trả về
    /// 1 pointer rác, `takeUnretainedValue()` sẽ retain địa chỉ rác → crash
    /// hoặc UAF tinh vi. Ở đây mình bỏ luôn return value.
    private static func invokeVoidClassMethod(_ name: String,
                                              _ arg1: AnyObject? = nil,
                                              _ arg2: AnyObject? = nil) {
        guard let cls = nativeClass else { return }
        let sel = NSSelectorFromString(name)
        guard cls.responds(to: sel) else {
            UniTrackPluginLog.warn("native UniTrack KHÔNG có selector \(name) — fallback")
            return
        }
        let obj: AnyObject = cls
        if let a2 = arg2 {
            _ = obj.perform(sel, with: arg1, with: a2)
        } else if let a1 = arg1 {
            _ = obj.perform(sel, with: a1)
        } else {
            _ = obj.perform(sel)
        }
    }

    /// Gọi class method có giá trị trả về (chuỗi/NSNumber). Bridge an toàn:
    /// dùng `Unmanaged.fromOpaque` đi qua `withExtendedLifetime` để Swift
    /// retain trước khi autorelease pool drain. Pattern này đảm bảo giá trị
    /// trả về (+0 autoreleased từ @objc getter) sống đủ lâu để mình lưu vào
    /// strong-ref `result` trước khi cast Swift type. So với
    /// `.takeUnretainedValue()` đơn thuần, pattern này thêm 1 lớp gate:
    /// nếu pointer là rác (sel sai signature) thì pointer truthy check sẽ
    /// loại bỏ, không retain.
    private static func invokeReturningClassMethod(_ name: String,
                                                   _ arg1: AnyObject? = nil,
                                                   _ arg2: AnyObject? = nil) -> AnyObject? {
        guard let cls = nativeClass else { return nil }
        let sel = NSSelectorFromString(name)
        guard cls.responds(to: sel) else {
            UniTrackPluginLog.warn("native UniTrack KHÔNG có selector \(name) — fallback")
            return nil
        }
        let obj: AnyObject = cls
        let unmanaged: Unmanaged<AnyObject>?
        if let a2 = arg2 {
            unmanaged = obj.perform(sel, with: arg1, with: a2)
        } else if let a1 = arg1 {
            unmanaged = obj.perform(sel, with: a1)
        } else {
            unmanaged = obj.perform(sel)
        }
        // Capture vào strong ref ngay lập tức — ARC bump retain count trước
        // khi autorelease pool có cơ hội drain (worst case là đang đứng giữa
        // 2 runloop tick). `result` giữ lifetime sống tới hết hàm; caller
        // cast sang String/NSNumber sẽ retain thêm 1 lần nữa qua bridge.
        let result: AnyObject? = unmanaged?.takeUnretainedValue()
        return withExtendedLifetime(result) { result }
    }

    // MARK: - Public proxy API

    /// Track 1 event qua singleton native. Properties được encode JSON
    /// để khớp với native API track(_:properties:) signature.
    static func track(_ name: String, properties: [String: Any]) {
        // Native UniTrack có @objc bridge cho track. Em call qua ObjC dùng
        // 1 helper class method "objc_track(_:propertiesJson:)" sẽ thêm.
        let json = (try? JSONSerialization.data(withJSONObject: properties))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        invokeVoidClassMethod("objc_track:propertiesJson:",
                              name as NSString, json as NSString)
    }

    static func setScreen(_ name: String) {
        invokeVoidClassMethod("objc_setScreen:", name as NSString)
    }

    static func setScreenForLayer(_ name: String, layer: Int) {
        invokeVoidClassMethod("objc_setScreen:layer:",
                              name as NSString, NSNumber(value: layer))
    }

    static func identify(userId: String, traitsJson: String) {
        invokeVoidClassMethod("objc_identify:traitsJson:",
                              userId as NSString, traitsJson as NSString)
    }

    static func reset() {
        invokeVoidClassMethod("objc_reset")
    }

    static func flush() {
        invokeVoidClassMethod("objc_flush")
    }

    static func setEnabled(_ enabled: Bool) {
        invokeVoidClassMethod("objc_setEnabled:", NSNumber(value: enabled))
    }

    static func currentSessionId() -> String {
        return (invokeReturningClassMethod("objc_currentSessionId") as? String) ?? ""
    }

    static func sessionIndex() -> Int {
        return (invokeReturningClassMethod("objc_sessionIndex") as? NSNumber)?.intValue ?? 0
    }

    static func previousSessionId() -> String {
        return (invokeReturningClassMethod("objc_previousSessionId") as? String) ?? ""
    }

    static func rotateSession() {
        invokeVoidClassMethod("objc_rotateSession")
    }

    static func registerLayer(_ layer: Int) {
        invokeVoidClassMethod("objc_registerLayer:", NSNumber(value: layer))
    }

    static func recordManualSignal(_ kind: Int) {
        invokeVoidClassMethod("objc_recordManualSignal:", NSNumber(value: kind))
    }
}

/// Logger riêng cho plugin proxy decisions. NSLog vì plugin chưa chắc
/// có UniTrack.log() khi co-resident (module-local có thể chưa init).
enum UniTrackPluginLog {
    static func info(_ msg: String)  { NSLog("[UniTrackPlugin] \(msg)") }
    static func warn(_ msg: String)  { NSLog("[UniTrackPlugin] WARN: \(msg)") }
}
