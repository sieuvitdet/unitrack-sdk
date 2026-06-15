// UniTrackConfigStream.swift
//
// SSE (Server-Sent Events) client for realtime portal config updates. While
// the regular fetch flow (UniTrackRemoteConfig.fetch) handles cold start +
// foreground throttle, this class holds an open HTTP connection to the
// portal so a config change in the operator UI lands on the app within
// seconds, not minutes.
//
//   UniTrackConfigStream.shared.start(
//       apiKey:    "utk_...",
//       streamURL: "https://mobix.asia/event-tracking-mobile/config/stream",
//       flavor:    "beta") {
//     // Fires on the main thread each time the portal pushed config_changed.
//     // Hosts typically re-call UniTrackRemoteConfig.fetch and re-apply.
//   }
//
//   UniTrackConfigStream.shared.stop()  // app background, logout, ...
//
// Behaviour:
//   • Auto-reconnects with exponential backoff (1s, 2s, 4s, max 30s) on any
//     transport error or clean close.
//   • Lifecycle-aware: pauses on UIApplication.didEnterBackground and resumes
//     on didBecomeActive so iOS doesn't waste a long-poll budget on a
//     suspended app.
//   • Heartbeat-tolerant: the server sends `: ping` comment lines every 25s
//     to keep proxies happy; the client silently ignores SSE comments.
//   • Coalesces rapid bursts: a flood of config_changed events within 500ms
//     of each other triggers the host callback once (operator may save 3
//     times in quick succession — the SDK shouldn't refetch thrice).

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class UniTrackConfigStream: NSObject {

    public static let shared = UniTrackConfigStream()

    private var apiKey: String = ""
    private var streamURL: String = ""
    private var flavor: String?
    private var onConfigChanged: (() -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var backoffSec: TimeInterval = 1
    private var bufferedLine = ""
    private var lastEventType = ""
    private var coalesceTimer: DispatchSourceTimer?
    private var stopped = true

    /// Tunable per-host: how long to wait before firing the callback after a
    /// burst of config_changed events. Lets the operator save several blocks
    /// without the SDK refetching every save.
    public var coalesceWindowMs: Int = 500

    /// Start the stream. Idempotent — calling again with the same args reuses
    /// the existing connection; with different args the old connection closes
    /// and a new one opens.
    public func start(apiKey: String,
                      streamURL: String,
                      flavor: String? = nil,
                      onConfigChanged: @escaping () -> Void) {
        // Same-args re-call: keep current connection.
        if self.task != nil
            && self.apiKey == apiKey
            && self.streamURL == streamURL
            && self.flavor == flavor {
            self.onConfigChanged = onConfigChanged
            return
        }
        stop()
        self.apiKey = apiKey
        self.streamURL = streamURL
        self.flavor = flavor
        self.onConfigChanged = onConfigChanged
        self.stopped = false
        installLifecycleObservers()
        connect()
    }

    /// Tear down the connection + cancel any pending reconnect. Call from
    /// app teardown (vd logout) when the host doesn't want push updates any
    /// more. The lifecycle observer will NOT automatically reopen after stop.
    public func stop() {
        stopped = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        coalesceTimer?.cancel()
        coalesceTimer = nil
        bufferedLine = ""
        lastEventType = ""
        backoffSec = 1
    }

    // MARK: - Connection

    private func connect() {
        guard !stopped else { return }
        var components = URLComponents(string: streamURL)
        if let flavor = flavor, !flavor.isEmpty {
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "flavor", value: flavor))
            components?.queryItems = items
        }
        guard let url = components?.url else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream",  forHTTPHeaderField: "Accept")
        req.setValue("no-cache",           forHTTPHeaderField: "Cache-Control")
        if let flavor = flavor, !flavor.isEmpty {
            req.setValue(flavor, forHTTPHeaderField: "X-UniTrack-Flavor")
        }
        // No timeout — SSE streams are long-lived by design.
        req.timeoutInterval = .greatestFiniteMagnitude

        // One session per attempt so invalidating the old one on reconnect
        // doesn't race with the new task. URLSessionDataDelegate gives us
        // per-chunk streaming via didReceive data.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .greatestFiniteMagnitude
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = s
        let t = s.dataTask(with: req)
        self.task = t
        t.resume()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = backoffSec
        backoffSec = min(backoffSec * 2, 30)   // 1 → 2 → 4 → 8 → 16 → 30
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - SSE parsing
    //
    // SSE messages are line-delimited blocks separated by blank lines. We only
    // care about the `event:` + `data:` fields; the spec also allows `id:` and
    // `retry:` (we ignore both for now — server-side reconnect window matches
    // our local backoff). Comments start with `:`.

    fileprivate func ingest(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        // Accumulate against any incomplete line from the previous chunk.
        bufferedLine += text
        // Process every complete line; keep the trailing fragment in buffer.
        while let nlIdx = bufferedLine.firstIndex(of: "\n") {
            let line = String(bufferedLine[..<nlIdx])
            bufferedLine.removeSubrange(bufferedLine.startIndex...nlIdx)
            handleLine(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
    }

    private func handleLine(_ line: String) {
        if line.isEmpty {
            // End of an event block — if the event we just buffered was
            // config_changed, schedule the host callback (coalesced).
            if lastEventType == "config_changed" {
                scheduleCoalescedCallback()
            }
            lastEventType = ""
            return
        }
        if line.hasPrefix(":") { return }   // SSE comment / heartbeat
        if line.hasPrefix("event:") {
            lastEventType = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
        }
        // We don't actually read `data:` — the only event we care about
        // (config_changed) carries the version in its data field, but the
        // host callback re-fetches the full config anyway so the version
        // hint is informational. Skipping the JSON parse keeps this lean.
    }

    private func scheduleCoalescedCallback() {
        coalesceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(coalesceWindowMs))
        t.setEventHandler { [weak self] in
            self?.onConfigChanged?()
        }
        t.resume()
        coalesceTimer = t
    }

    // MARK: - Lifecycle

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        // Pause on background so iOS doesn't bill us for a suspended HTTP
        // long-poll; resume on foreground with backoff reset so the first
        // reconnect is immediate.
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.task?.cancel()
            self?.task = nil
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.stopped, self.task == nil else { return }
            self.backoffSec = 1
            self.connect()
        }
        #endif
    }
}

// MARK: - URLSessionDataDelegate

extension UniTrackConfigStream: URLSessionDataDelegate {

    public func urlSession(_ session: URLSession,
                           dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        if http.statusCode == 200 {
            backoffSec = 1   // reset backoff once the server accepted us
            completionHandler(.allow)
        } else {
            // 401 / 403 / 5xx — close + reconnect with backoff. 4xx will
            // keep failing until the operator fixes the api_key; keeping a
            // (slow) backoff avoids hammering the portal.
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession,
                           dataTask: URLSessionDataTask,
                           didReceive data: Data) {
        ingest(data)
    }

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        // Server closed the stream OR transport error. Reconnect either way
        // unless the host explicitly stopped us.
        self.task = nil
        if !stopped { scheduleReconnect() }
    }
}
