// RNUniTrack.swift — React Native iOS bridge implementation.
//
// Forwards JS calls to the UniTrack iOS Swift SDK linked alongside (vendored
// into Native/ by sync_native.sh, just like the Flutter plugin). Method
// declarations live in RNUniTrack.m via RCT_EXTERN_METHOD so RN's bridge
// can find them — without that file Swift methods are invisible to JS.

import Foundation
import React

@objc(UniTrack)
public class RNUniTrack: RCTEventEmitter {

    private var hasListeners = false

    public override init() {
        super.init()
    }

    @objc public static override func requiresMainQueueSetup() -> Bool { false }

    public override func supportedEvents() -> [String] {
        // Single event so the JS side can subscribe via
        // `NativeEventEmitter(NativeModules.UniTrack).addListener('onFlushCompleted', …)`.
        return ["onFlushCompleted"]
    }
    public override func startObserving()  { hasListeners = true  }
    public override func stopObserving()   { hasListeners = false }

    // ── helpers ───────────────────────────────────────────────────────────

    private func dict(from json: String?) -> [String: Any] {
        guard let s = json, !s.isEmpty,
              let data = s.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    // ── Core ──────────────────────────────────────────────────────────────

    @objc(initialize:config:resolver:rejecter:)
    func initialize(_ apiKey: String, configJson: String,
                    resolver resolve: @escaping RCTPromiseResolveBlock,
                    rejecter reject: @escaping RCTPromiseRejectBlock) {
        let c = dict(from: configJson)
        var cfg = UniTrack.Config()
        if let v = c["endpoint"]         as? String { cfg.endpoint        = v }
        if let v = c["batchSize"]        as? Int    { cfg.batchSize       = v }
        if let v = c["flushIntervalMs"]  as? Int    { cfg.flushIntervalMs = v }
        if let v = c["samplingRate"]     as? Double { cfg.samplingRate    = v }
        if let v = c["autoCapture"]      as? Bool   { cfg.autoCapture     = v }
        if let v = c["trackScreens"]     as? Bool   { cfg.trackScreens    = v }
        if let v = c["trackTaps"]        as? Bool   { cfg.trackTaps       = v }
        if let v = c["trackNetwork"]     as? Bool   { cfg.trackNetwork    = v }
        if let v = c["journeyCapture"]   as? Bool   { cfg.journeyCapture  = v }
        if let v = c["sessionTimeoutMs"] as? Int    { cfg.sessionTimeoutMs = v }
        if let v = c["screenLoadEvent"]  as? String, !v.isEmpty { cfg.screenLoadEvent = v }
        UniTrack.initialize(apiKey: apiKey, config: cfg)
        resolve(nil)
    }

    @objc(identify:traits:resolver:rejecter:)
    func identify(_ userId: String, traitsJson: String,
                  resolver resolve: @escaping RCTPromiseResolveBlock,
                  rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.identify(userId: userId, traits: dict(from: traitsJson))
        resolve(nil)
    }

    @objc(reset:rejecter:)
    func reset(_ resolve: @escaping RCTPromiseResolveBlock,
               rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.reset(); resolve(nil)
    }

    @objc(track:props:resolver:rejecter:)
    func track(_ event: String, propsJson: String,
               resolver resolve: @escaping RCTPromiseResolveBlock,
               rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.track(event, properties: dict(from: propsJson))
        resolve(nil)
    }

    @objc(setScreen:resolver:rejecter:)
    func setScreen(_ name: String,
                   resolver resolve: @escaping RCTPromiseResolveBlock,
                   rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.setScreen(name); resolve(nil)
    }

    @objc(flush:rejecter:)
    func flush(_ resolve: @escaping RCTPromiseResolveBlock,
               rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.flush(); resolve(nil)
    }

    @objc(setEnabled:resolver:rejecter:)
    func setEnabled(_ enabled: Bool,
                    resolver resolve: @escaping RCTPromiseResolveBlock,
                    rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.setEnabled(enabled); resolve(nil)
    }

    // ── Session API ───────────────────────────────────────────────────────

    @objc(currentSessionId:rejecter:)
    func currentSessionId(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.currentSessionId())
    }

    @objc(sessionIndex:rejecter:)
    func sessionIndex(_ resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.sessionIndex())
    }

    @objc(previousSessionId:rejecter:)
    func previousSessionId(_ resolve: @escaping RCTPromiseResolveBlock,
                           rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.previousSessionId())
    }

    @objc(rotateSession:rejecter:)
    func rotateSession(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.rotateSession(); resolve(nil)
    }

    // ── Offline queue + flush callback ────────────────────────────────────

    @objc(pendingEventCounts:rejecter:)
    func pendingEventCounts(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.pendingEventCounts())
    }

    @objc(setFlushCallbackEnabled:resolver:rejecter:)
    func setFlushCallbackEnabled(_ enabled: Bool,
                                 resolver resolve: @escaping RCTPromiseResolveBlock,
                                 rejecter reject: @escaping RCTPromiseRejectBlock) {
        if enabled {
            UniTrack.onFlushCompleted { [weak self] counts in
                guard let self = self, self.hasListeners else { return }
                // RCTEventEmitter hops to the JS thread itself; safe to call
                // from the SDK worker thread.
                self.sendEvent(withName: "onFlushCompleted",
                               body: ["counts": counts])
            }
        } else {
            UniTrack.onFlushCompleted(nil)
        }
        resolve(nil)
    }

    // ── Application context + remote values ───────────────────────────────

    @objc(applicationContext:rejecter:)
    func applicationContext(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.applicationContext())
    }

    @objc(getRemoteValue:type:resolver:rejecter:)
    func getRemoteValue(_ key: String, type: String,
                        resolver resolve: @escaping RCTPromiseResolveBlock,
                        rejecter reject: @escaping RCTPromiseRejectBlock) {
        switch type {
        case "bool":   resolve(UniTrack.getRemoteValue(key, default: false))
        case "int":    resolve(UniTrack.getRemoteValue(key, default: 0))
        case "double": resolve(UniTrack.getRemoteValue(key, default: 0.0))
        default:       resolve(UniTrack.getRemoteValue(key, default: ""))
        }
    }

    // ── Session stat sidebag ──────────────────────────────────────────────

    @objc(sessionScreenCount:rejecter:)
    func sessionScreenCount(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.sessionScreenCount())
    }
    @objc(sessionHadError:rejecter:)
    func sessionHadError(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.sessionHadError())
    }
    @objc(sessionHadCrash:rejecter:)
    func sessionHadCrash(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(UniTrack.sessionHadCrash())
    }
    @objc(incrementScreenCount:rejecter:)
    func incrementScreenCount(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.incrementScreenCount(); resolve(nil)
    }
    @objc(markSessionError:rejecter:)
    func markSessionError(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.markSessionError(); resolve(nil)
    }
    @objc(markSessionCrash:rejecter:)
    func markSessionCrash(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.markSessionCrash(); resolve(nil)
    }
    @objc(resetSessionStats:rejecter:)
    func resetSessionStats(_ resolve: @escaping RCTPromiseResolveBlock,
                           rejecter reject: @escaping RCTPromiseRejectBlock) {
        UniTrack.resetSessionStats(); resolve(nil)
    }
}
