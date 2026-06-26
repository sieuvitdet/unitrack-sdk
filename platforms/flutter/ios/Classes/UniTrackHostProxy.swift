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

    /// Gọi class method 0..2 arg trên native UniTrack class qua ObjC runtime.
    /// Return raw AnyObject; caller cast về type mong đợi.
    /// Selector phải @objc-exposed bên native side — em đã đánh dấu các
    /// API cần share trong UniTrack.swift native (track, currentSessionId,
    /// setScreen, identify, reset, flush, sessionIndex, previousSessionId).
    @discardableResult
    private static func invokeClassMethod(_ name: String,
                                          _ arg1: AnyObject? = nil,
                                          _ arg2: AnyObject? = nil) -> AnyObject? {
        guard let cls = nativeClass else { return nil }
        let sel = NSSelectorFromString(name)
        guard cls.responds(to: sel) else {
            UniTrackPluginLog.warn("native UniTrack KHÔNG có selector \(name) — fallback")
            return nil
        }
        let obj: AnyObject = cls
        if let a2 = arg2 {
            return obj.perform(sel, with: arg1, with: a2)?.takeUnretainedValue()
        }
        if let a1 = arg1 {
            return obj.perform(sel, with: a1)?.takeUnretainedValue()
        }
        return obj.perform(sel)?.takeUnretainedValue()
    }

    // MARK: - Public proxy API

    /// Track 1 event qua singleton native. Properties được encode JSON
    /// để khớp với native API track(_:properties:) signature.
    static func track(_ name: String, properties: [String: Any]) {
        // Native UniTrack có @objc bridge cho track. Em call qua ObjC dùng
        // 1 helper class method "objc_track(_:propertiesJson:)" sẽ thêm.
        let json = (try? JSONSerialization.data(withJSONObject: properties))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        invokeClassMethod("objc_track:propertiesJson:",
                          name as NSString, json as NSString)
    }

    static func setScreen(_ name: String) {
        invokeClassMethod("objc_setScreen:", name as NSString)
    }

    static func setScreenForLayer(_ name: String, layer: Int) {
        invokeClassMethod("objc_setScreen:layer:",
                          name as NSString, NSNumber(value: layer))
    }

    static func identify(userId: String, traitsJson: String) {
        invokeClassMethod("objc_identify:traitsJson:",
                          userId as NSString, traitsJson as NSString)
    }

    static func reset() {
        invokeClassMethod("objc_reset")
    }

    static func flush() {
        invokeClassMethod("objc_flush")
    }

    static func setEnabled(_ enabled: Bool) {
        invokeClassMethod("objc_setEnabled:", NSNumber(value: enabled))
    }

    static func currentSessionId() -> String {
        return (invokeClassMethod("objc_currentSessionId") as? String) ?? ""
    }

    static func sessionIndex() -> Int {
        return (invokeClassMethod("objc_sessionIndex") as? NSNumber)?.intValue ?? 0
    }

    static func previousSessionId() -> String {
        return (invokeClassMethod("objc_previousSessionId") as? String) ?? ""
    }

    static func rotateSession() {
        invokeClassMethod("objc_rotateSession")
    }

    static func registerLayer(_ layer: Int) {
        invokeClassMethod("objc_registerLayer:", NSNumber(value: layer))
    }

    static func recordManualSignal(_ kind: Int) {
        invokeClassMethod("objc_recordManualSignal:", NSNumber(value: kind))
    }
}

/// Logger riêng cho plugin proxy decisions. NSLog vì plugin chưa chắc
/// có UniTrack.log() khi co-resident (module-local có thể chưa init).
enum UniTrackPluginLog {
    static func info(_ msg: String)  { NSLog("[UniTrackPlugin] \(msg)") }
    static func warn(_ msg: String)  { NSLog("[UniTrackPlugin] WARN: \(msg)") }
}
