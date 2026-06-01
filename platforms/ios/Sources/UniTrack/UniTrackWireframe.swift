// UniTrackWireframe.swift
//
// Capture a snapshot of the current screen's view tree — every UIView with
// its type, frame, and the few attributes that matter for visual replay
// (label text, accessibilityIdentifier, isHidden, alpha). The portal stores
// the JSON and renders it as an SVG outline on the Layout tab so an operator
// sees what the user saw, including custom widgets, overrides, and the
// sub-trees behind them.
//
// Trigger: app calls `UniTrackWireframe.snapshotCurrentScreen()` once per
// screen — typically inside the existing viewDidAppear swizzle path. We
// don't auto-install here because viewDidAppear fires very often and we
// don't want every revisit of the same screen to re-walk the tree (would
// double the bandwidth + storage).
//
// Cost: a typical screen has 50–200 UIViews. The serialised JSON is
// 5–20 KB, gzipped → 1–4 KB. We truncate at 500 nodes to keep the payload
// bounded for outlier layouts.

import Foundation
import UIKit
import Compression

public enum UniTrackWireframe {

    /// Max nodes to serialise before flagging `truncated`. Bigger trees lose
    /// their tail; the head usually has the meaningful container hierarchy.
    public static var maxNodes: Int = 500

    /// Walk the key window's root view tree and emit a `screen_layout` event
    /// carrying the gzipped JSON. Safe to call from any thread — we hop to
    /// main for the actual walk (UIView access must be main-thread).
    public static func snapshotCurrentScreen() {
        DispatchQueue.main.async {
            guard let root = keyWindow()?.rootViewController?.view else { return }
            var counter = 0
            let dict = walk(root, counter: &counter, parentOrigin: .zero)
            let truncated = counter >= maxNodes
            // Tree is JSON-serialisable by construction (only strings, numbers,
            // bools, dicts, arrays). One try? to satisfy JSONSerialization.
            guard let json = try? JSONSerialization.data(withJSONObject: dict, options: []),
                  let gz = gzip(json) else { return }
            let b64 = gz.base64EncodedString()
            UniTrack.track("screen_layout", properties: [
                "tree_b64gz": b64,
                "node_count": counter,
                "truncated":  truncated,
                "framework":  "uikit",
            ])
        }
    }

    // ── tree walk ────────────────────────────────────────────────────────

    private static func walk(_ view: UIView,
                             counter: inout Int,
                             parentOrigin: CGPoint) -> [String: Any] {
        counter += 1
        // Convert to absolute (window) coordinates — easier to render on the
        // portal where the original parent transform isn't available.
        let abs = view.convert(view.bounds, to: nil)
        var node: [String: Any] = [
            "id":   counter,
            "type": String(describing: type(of: view)),
            "x":    Int(abs.origin.x),
            "y":    Int(abs.origin.y),
            "w":    Int(abs.size.width),
            "h":    Int(abs.size.height),
        ]
        if view.isHidden            { node["hidden"] = true }
        if view.alpha < 0.99        { node["alpha"]  = view.alpha }
        if let id = view.accessibilityIdentifier, !id.isEmpty { node["aid"] = id }
        if let lbl = (view as? UILabel)?.text, !lbl.isEmpty   { node["text"] = trim(lbl) }
        if let btn = (view as? UIButton)?.title(for: .normal), !btn.isEmpty {
            node["text"] = trim(btn)
        }
        if counter >= maxNodes { return node }   // stop descending — truncated

        // Children walked depth-first. Skip children if already past the cap.
        if !view.subviews.isEmpty {
            var children: [[String: Any]] = []
            children.reserveCapacity(view.subviews.count)
            for child in view.subviews {
                children.append(walk(child, counter: &counter, parentOrigin: abs.origin))
                if counter >= maxNodes { break }
            }
            if !children.isEmpty { node["children"] = children }
        }
        return node
    }

    /// Truncate display strings — wireframe doesn't need a full paragraph.
    private static func trim(_ s: String) -> String {
        s.count > 64 ? String(s.prefix(63)) + "…" : s
    }

    // ── helpers ──────────────────────────────────────────────────────────

    private static func keyWindow() -> UIWindow? {
        // iOS 13+ multi-scene — pick the first key window from any active scene.
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: { $0.isKeyWindow }) { return key }
            if let first = ws.windows.first { return first }
        }
        return nil
    }

    /// Gzip with Compression framework's `COMPRESSION_ZLIB`. Returns nil on
    /// allocation failure — the caller treats nil as "skip this snapshot".
    private static func gzip(_ data: Data) -> Data? {
        let bufferSize = 64 * 1024
        let dstSize = data.count + bufferSize    // ample
        var dst = Data(count: dstSize)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                guard let srcAddr = srcPtr.baseAddress,
                      let dstAddr = dstPtr.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstAddr.assumingMemoryBound(to: UInt8.self), dstSize,
                    srcAddr.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }
}
