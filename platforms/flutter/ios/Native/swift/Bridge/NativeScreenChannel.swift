// NativeScreenChannel.swift
//
// Reverse-direction notification: when the iOS swizzler emits a screen for a
// native VC, we ALSO publish the name into this in-process channel so a
// cross-platform layer (Flutter NavigatorObserver, RN navigation listener)
// can update its `currentScreen` mirror — used for tap attribution when the
// user is on a native screen reached from inside a Flutter/RN app.
//
// One channel, many subscribers. The Flutter plugin subscribes at
// `UnitrackPlugin.register` time and forwards each event over its
// MethodChannel to Dart. RN plugin will use a NativeEventEmitter. The
// channel itself doesn't know about Flutter or RN — it just dispatches
// `(screen, layer)` tuples on the calling thread.
//
// All operations are thread-safe; subscribers are invoked synchronously
// from inside `broadcast`. Keep handlers cheap (just hop to your channel
// and let the receiving side handle it async).

import Foundation

enum NativeScreenChannel {

    /// Callback shape: (screen name, layer that emitted it). The layer is
    /// included so subscribers can ignore self-broadcasts (vd Flutter
    /// subscribes but ignores `layer == .flutter`).
    typealias Handler = (_ screen: String, _ layer: UniTrackLayer) -> Void

    private static let lock = NSLock()
    private static var nextToken: Int = 0
    private static var handlers: [Int: Handler] = [:]

    /// Subscribe to native screen emissions. Returns a token used to
    /// unsubscribe. Safe to call before UniTrack.initialize.
    @discardableResult
    static func subscribe(_ handler: @escaping Handler) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextToken += 1
        let token = nextToken
        handlers[token] = handler
        return token
    }

    static func unsubscribe(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: token)
    }

    /// Publish a screen emission to all subscribers. No-op when no subscriber
    /// is registered — the common case for native-only apps with no Flutter
    /// or RN plugin loaded.
    static func broadcast(screen: String, from layer: UniTrackLayer) {
        let snapshot: [Handler]
        lock.lock()
        snapshot = Array(handlers.values)
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        for h in snapshot { h(screen, layer) }
    }
}
